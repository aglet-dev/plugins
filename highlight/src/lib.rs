//! highlight plugin —— syntax highlighting via tree-sitter，输出 IR rich-text runs。
//!
//! action="render"
//!   params: {"code":"fn main(){}", "lang":"rust"}
//!   result: {"ok":true,"data":{"runs":[{"text":"fn","hl":"keyword"},{"text":" main"},...]}}
//!
//! 输出 runs（{text, hl?}）而非 HTML —— renderer-agnostic：web 渲成 <span class=hl-*>，
//! native(SwiftUI/Compose) 渲成带色的 AttributedString/AnnotatedString（见 Aglet 的
//! Text.runs）。hl = tree-sitter capture 的首段语义（keyword/string/comment/...）。
//! 不支持的语言 / 解析失败 → 单个无 hl 的纯文本 run。

use aglet_plugin_sdk as sdk;
use serde_json::{json, Value};
use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

/// tree-sitter 标准 capture 名集合（configure 顺序 = HighlightEvent 的 index）。
static HIGHLIGHT_NAMES: &[&str] = &[
    "attribute",
    "comment",
    "constant",
    "constant.builtin",
    "constructor",
    "escape",
    "function",
    "function.builtin",
    "function.method",
    "keyword",
    "label",
    "module",
    "number",
    "operator",
    "property",
    "punctuation",
    "punctuation.bracket",
    "punctuation.delimiter",
    "string",
    "string.special",
    "tag",
    "type",
    "type.builtin",
    "variable",
    "variable.builtin",
    "variable.parameter",
];

/// (tree_sitter::Language, highlights query) by lang token。返 None = 不支持。
fn lang_config(lang: &str) -> Option<(tree_sitter::Language, &'static str)> {
    match lang {
        "rust" | "rs" => Some((tree_sitter_rust::LANGUAGE.into(), tree_sitter_rust::HIGHLIGHTS_QUERY)),
        "json" => Some((tree_sitter_json::LANGUAGE.into(), tree_sitter_json::HIGHLIGHTS_QUERY)),
        "python" | "py" => Some((tree_sitter_python::LANGUAGE.into(), tree_sitter_python::HIGHLIGHTS_QUERY)),
        "javascript" | "js" | "jsx" => Some((tree_sitter_javascript::LANGUAGE.into(), tree_sitter_javascript::HIGHLIGHT_QUERY)),
        "bash" | "sh" | "shell" | "zsh" => Some((tree_sitter_bash::LANGUAGE.into(), tree_sitter_bash::HIGHLIGHT_QUERY)),
        "c" | "h" => Some((tree_sitter_c::LANGUAGE.into(), tree_sitter_c::HIGHLIGHT_QUERY)),
        "go" => Some((tree_sitter_go::LANGUAGE.into(), tree_sitter_go::HIGHLIGHTS_QUERY)),
        _ => None,
    }
}

struct Run {
    text: String,
    hl: Option<String>,
}

fn handle(action: &str, params: &str) -> String {
    match action {
        "render" => do_render(params),
        _ => sdk::err("UNKNOWN_ACTION", action),
    }
}

fn do_render(params: &str) -> String {
    let v: Value = match serde_json::from_str(params) {
        Ok(v) => v,
        Err(e) => return sdk::err_invalid(&format!("bad params json: {}", e)),
    };
    let code = v.get("code").and_then(Value::as_str).unwrap_or("");
    let lang = v.get("lang").and_then(Value::as_str).unwrap_or("");

    // 不支持的语言 / 解析失败 → 单个纯文本 run（仍是合法 runs）。
    let runs = highlight_runs(code, lang).unwrap_or_else(|| {
        vec![Run { text: code.to_string(), hl: None }]
    });

    let arr: Vec<Value> = runs
        .iter()
        .map(|r| {
            let mut o = serde_json::Map::new();
            o.insert("text".into(), json!(r.text));
            if let Some(h) = &r.hl {
                o.insert("hl".into(), json!(h));
            }
            Value::Object(o)
        })
        .collect();
    let data = format!("{{\"runs\":{}}}", serde_json::to_string(&arr).unwrap());
    sdk::ok_data(&data)
}

fn highlight_runs(code: &str, lang: &str) -> Option<Vec<Run>> {
    let (language, query) = lang_config(lang)?;
    let mut config = HighlightConfiguration::new(language, lang, query, "", "").ok()?;
    config.configure(HIGHLIGHT_NAMES);

    let mut highlighter = Highlighter::new();
    let events = highlighter
        .highlight(&config, code.as_bytes(), None, |_| None)
        .ok()?;

    let mut runs: Vec<Run> = Vec::new();
    let mut stack: Vec<usize> = Vec::new(); // 当前 highlight 语义栈（index 进 HIGHLIGHT_NAMES）
    for ev in events {
        match ev.ok()? {
            HighlightEvent::Source { start, end } => {
                let text = code.get(start..end).unwrap_or("");
                if text.is_empty() {
                    continue;
                }
                // 取栈顶语义的首段（"function.method" → "function"），跨端 hl-* 类/色对齐。
                let sem = stack.last().map(|&i| {
                    let name = HIGHLIGHT_NAMES[i];
                    name.split('.').next().unwrap_or(name).to_string()
                });
                // 合并相邻同 hl 的 run。
                if let Some(last) = runs.last_mut() {
                    if last.hl == sem {
                        last.text.push_str(text);
                        continue;
                    }
                }
                runs.push(Run { text: text.to_string(), hl: sem });
            }
            HighlightEvent::HighlightStart(h) => stack.push(h.0),
            HighlightEvent::HighlightEnd => {
                stack.pop();
            }
        }
    }
    Some(runs)
}

sdk::export_plugin!(handle);
