//! markdown plugin —— CommonMark + GFM → Aglet IR node 树（comrak）。
//!
//! action="render"
//!   params: {"text":"# hi\n\n- a\n\n```rust\nfn x(){}\n```"}
//!   result: {"ok":true,"data":{"nodes":[ <IR node>, ... ]}}
//!
//! 输出 canonical IR node 树（非 HTML）—— renderer-agnostic：web/native 用现有组件
//! 直接渲（段落=Text+runs、heading=Heading、fenced code=CodeBlock、列表=带项目符 Text）。
//! 见 aglet docs/NATIVE_MARKDOWN_IR.md。
//!
//! IR node = {"type": "...", "props": {...}}。行内样式 → Text.runs（{text,marks?,href?}）。

use aglet_plugin_sdk as sdk;
use comrak::nodes::{AstNode, ListType, NodeValue};
use comrak::{parse_document, Arena, Options};
use serde_json::{json, Map, Value};

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
    let text = v.get("text").and_then(Value::as_str).unwrap_or("");

    let arena = Arena::new();
    let mut opts = Options::default();
    opts.extension.strikethrough = true;
    opts.extension.table = true;
    opts.extension.tasklist = true;
    opts.extension.autolink = true;
    let root = parse_document(&arena, text, &opts);

    let nodes = blocks_to_nodes(root);
    let data = format!("{{\"nodes\":{}}}", serde_json::to_string(&nodes).unwrap());
    sdk::ok_data(&data)
}

/// 把一个块容器（document / blockquote / list-item）的 block 子节点转成 IR node 列表。
fn blocks_to_nodes<'a>(node: &'a AstNode<'a>) -> Vec<Value> {
    let mut out = Vec::new();
    for child in node.children() {
        let nv = child.data.borrow().value.clone();
        match nv {
            NodeValue::Heading(h) => {
                out.push(json!({
                    "type": "Heading",
                    "props": { "level": h.level, "content": inline_plain(child) }
                }));
            }
            NodeValue::Paragraph => {
                out.push(json!({ "type": "Text", "props": { "runs": inline_runs(child) } }));
            }
            NodeValue::CodeBlock(cb) => {
                let lang = cb.info.split_whitespace().next().unwrap_or("").to_string();
                out.push(json!({
                    "type": "CodeBlock",
                    "props": { "lang": lang, "code": cb.literal }
                }));
            }
            NodeValue::List(list) => {
                let ordered = matches!(list.list_type, ListType::Ordered);
                let mut idx = list.start;
                for item in child.children() {
                    let prefix = if ordered {
                        format!("{}. ", idx)
                    } else {
                        "• ".to_string()
                    };
                    idx += 1;
                    let mut runs = vec![json!({ "text": prefix })];
                    // 列表项内容（通常一个段落）的行内 runs 摊平进同一 Text。
                    for block in item.children() {
                        runs.extend(inline_runs(block));
                    }
                    out.push(json!({ "type": "Text", "props": { "runs": runs } }));
                }
            }
            NodeValue::ThematicBreak => {
                out.push(json!({ "type": "Divider", "props": {} }));
            }
            NodeValue::BlockQuote => {
                // 退化：摊平引用内的 block（暂无引用样式容器）。
                out.extend(blocks_to_nodes(child));
            }
            _ => {
                // 其它块（表格等暂未专门处理）：尽力当作行内 Text。
                let runs = inline_runs(child);
                if !runs.is_empty() {
                    out.push(json!({ "type": "Text", "props": { "runs": runs } }));
                }
            }
        }
    }
    out
}

/// 收集一个块的行内内容为 runs（{text, marks?, href?}）。
fn inline_runs<'a>(node: &'a AstNode<'a>) -> Vec<Value> {
    let mut out = Vec::new();
    collect_runs(node, &[], None, &mut out);
    out
}

fn collect_runs<'a>(node: &'a AstNode<'a>, marks: &[&str], href: Option<&str>, out: &mut Vec<Value>) {
    for child in node.children() {
        let nv = child.data.borrow().value.clone();
        match nv {
            NodeValue::Text(t) => push_run(out, &t, marks, href),
            NodeValue::Code(c) => {
                let mut m = marks.to_vec();
                m.push("code");
                push_run(out, &c.literal, &m, href);
            }
            NodeValue::Strong => {
                let mut m = marks.to_vec();
                m.push("strong");
                collect_runs(child, &m, href, out);
            }
            NodeValue::Emph => {
                let mut m = marks.to_vec();
                m.push("em");
                collect_runs(child, &m, href, out);
            }
            NodeValue::Strikethrough => {
                let mut m = marks.to_vec();
                m.push("strike");
                collect_runs(child, &m, href, out);
            }
            NodeValue::Link(l) => collect_runs(child, marks, Some(&l.url), out),
            NodeValue::SoftBreak => push_run(out, " ", marks, href),
            NodeValue::LineBreak => push_run(out, "\n", marks, href),
            _ => collect_runs(child, marks, href, out), // 其它行内容器：递归
        }
    }
}

fn push_run(out: &mut Vec<Value>, text: &str, marks: &[&str], href: Option<&str>) {
    if text.is_empty() {
        return;
    }
    let mut o = Map::new();
    o.insert("text".into(), json!(text));
    if !marks.is_empty() {
        o.insert("marks".into(), json!(marks));
    }
    if let Some(h) = href {
        o.insert("href".into(), json!(h));
    }
    out.push(Value::Object(o));
}

/// heading 用纯文本 content（Heading 节点只有 content:string，不带行内样式）。
fn inline_plain<'a>(node: &'a AstNode<'a>) -> String {
    let mut s = String::new();
    collect_plain(node, &mut s);
    s
}

fn collect_plain<'a>(node: &'a AstNode<'a>, s: &mut String) {
    for child in node.children() {
        let nv = child.data.borrow().value.clone();
        match nv {
            NodeValue::Text(t) => s.push_str(&t),
            NodeValue::Code(c) => s.push_str(&c.literal),
            NodeValue::SoftBreak | NodeValue::LineBreak => s.push(' '),
            _ => collect_plain(child, s),
        }
    }
}

sdk::export_plugin!(handle);
