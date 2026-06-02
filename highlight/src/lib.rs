//! highlight plugin —— syntax highlighting via tree-sitter.
//!
//! action="render"
//!   params: {"code":"fn main(){}", "lang":"rust"}
//!   result: {"ok":true,"data":{"html":"<span class=\"hl-keyword\">fn</span> ..."}}
//!
//! 输出是 class 化的 <span>（class="hl-<capture>"，如 hl-keyword / hl-string /
//! hl-comment），renderer/主题决定颜色。未知语言或解析失败 → 退化为 HTML 转义
//! 的纯文本（仍是合法 html）。

use aglet_plugin_sdk as sdk;
use serde_json::Value;
use tree_sitter_highlight::{HighlightConfiguration, Highlighter, HtmlRenderer};

/// tree-sitter 标准 capture 名集合。HtmlRenderer 回调按 index 映射到 class。
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
        "rust" | "rs" => Some((
            tree_sitter_rust::LANGUAGE.into(),
            tree_sitter_rust::HIGHLIGHTS_QUERY,
        )),
        "json" => Some((
            tree_sitter_json::LANGUAGE.into(),
            tree_sitter_json::HIGHLIGHTS_QUERY,
        )),
        "python" | "py" => Some((
            tree_sitter_python::LANGUAGE.into(),
            tree_sitter_python::HIGHLIGHTS_QUERY,
        )),
        "javascript" | "js" | "jsx" => Some((
            tree_sitter_javascript::LANGUAGE.into(),
            tree_sitter_javascript::HIGHLIGHT_QUERY,
        )),
        "bash" | "sh" | "shell" | "zsh" => Some((
            tree_sitter_bash::LANGUAGE.into(),
            tree_sitter_bash::HIGHLIGHT_QUERY,
        )),
        "c" | "h" => Some((
            tree_sitter_c::LANGUAGE.into(),
            tree_sitter_c::HIGHLIGHT_QUERY,
        )),
        "go" => Some((
            tree_sitter_go::LANGUAGE.into(),
            tree_sitter_go::HIGHLIGHTS_QUERY,
        )),
        _ => None,
    }
}

fn handle(action: &str, params: &str) -> String {
    match action {
        "render" => do_highlight(params),
        _ => sdk::err("UNKNOWN_ACTION", action),
    }
}

fn do_highlight(params: &str) -> String {
    let v: Value = match serde_json::from_str(params) {
        Ok(v) => v,
        Err(e) => return sdk::err_invalid(&format!("bad params json: {}", e)),
    };
    let code = v.get("code").and_then(Value::as_str).unwrap_or("");
    let lang = v.get("lang").and_then(Value::as_str).unwrap_or("");

    let html = match highlight_html(code, lang) {
        Some(h) => h,
        // 不支持的语言 / 解析失败 → 纯转义兜底（仍合法 html）。
        None => format!("<pre><code>{}</code></pre>", html_escape(code)),
    };
    let data = format!("{{\"html\":{}}}", serde_json::to_string(&html).unwrap());
    sdk::ok_data(&data)
}

fn highlight_html(code: &str, lang: &str) -> Option<String> {
    let (language, query) = lang_config(lang)?;

    let mut config = HighlightConfiguration::new(language, lang, query, "", "").ok()?;
    config.configure(HIGHLIGHT_NAMES);

    let class_attrs: Vec<String> = HIGHLIGHT_NAMES
        .iter()
        .map(|n| format!("class=\"hl-{}\"", n.replace('.', "-")))
        .collect();

    let mut highlighter = Highlighter::new();
    let highlights = highlighter
        .highlight(&config, code.as_bytes(), None, |_| None)
        .ok()?;

    let mut renderer = HtmlRenderer::new();
    renderer
        .render(highlights, code.as_bytes(), &|h, out| {
            out.extend_from_slice(class_attrs[h.0].as_bytes());
        })
        .ok()?;

    Some(renderer.lines().collect::<String>())
}

fn html_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            c => out.push(c),
        }
    }
    out
}

sdk::export_plugin!(handle);
