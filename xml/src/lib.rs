//! XML plugin — XML tree parsing plus RSS/Atom feed normalization.
//!
//! action="parse"
//!   params: {"text":"<root/>","trim_text":true,"max_nodes":5000}
//!   result: {"ok":true,"data":{"root":{...}}}
//!
//! action="rss"
//!   params: {"text":"<rss>...</rss>","limit":100}
//!   result: {"ok":true,"data":{"feed":{...},"items":[...]}}

use aglet_plugin_sdk as sdk;
use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;
use quick_xml::XmlVersion;
use serde_json::{json, Map, Value};

const DEFAULT_MAX_NODES: usize = 5_000;
const DEFAULT_RSS_LIMIT: usize = 100;

#[derive(Debug, Default)]
struct Node {
    name: String,
    attributes: Map<String, Value>,
    children: Vec<Node>,
    text: String,
}

impl Node {
    fn new(name: String, attributes: Map<String, Value>) -> Self {
        Self {
            name,
            attributes,
            children: Vec::new(),
            text: String::new(),
        }
    }

    fn to_json(&self) -> Value {
        let mut o = Map::new();
        o.insert("name".into(), json!(self.name));
        if !self.attributes.is_empty() {
            o.insert("attributes".into(), Value::Object(self.attributes.clone()));
        }
        if !self.text.is_empty() {
            o.insert("text".into(), json!(self.text));
        }
        if !self.children.is_empty() {
            o.insert(
                "children".into(),
                Value::Array(self.children.iter().map(Node::to_json).collect()),
            );
        }
        Value::Object(o)
    }
}

fn handle(action: &str, params: &str) -> String {
    match action {
        "parse" => do_parse(params),
        "rss" => do_rss(params),
        _ => sdk::err("UNKNOWN_ACTION", action),
    }
}

fn do_parse(params: &str) -> String {
    let v: Value = match serde_json::from_str(params) {
        Ok(v) => v,
        Err(e) => return sdk::err_invalid(&format!("bad params json: {}", e)),
    };
    let text = v.get("text").and_then(Value::as_str).unwrap_or("");
    let trim = v.get("trim_text").and_then(Value::as_bool).unwrap_or(true);
    let max_nodes = v
        .get("max_nodes")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_MAX_NODES as u64) as usize;

    match parse_tree(text, trim, max_nodes) {
        Ok(Some(root)) => sdk::ok_data(&json!({ "root": root.to_json() }).to_string()),
        Ok(None) => sdk::ok_data("{\"root\":null}"),
        Err(e) => sdk::err_invalid(&e),
    }
}

fn do_rss(params: &str) -> String {
    let v: Value = match serde_json::from_str(params) {
        Ok(v) => v,
        Err(e) => return sdk::err_invalid(&format!("bad params json: {}", e)),
    };
    let text = v.get("text").and_then(Value::as_str).unwrap_or("");
    let limit = v
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_RSS_LIMIT as u64) as usize;

    let root = match parse_tree(text, true, DEFAULT_MAX_NODES.max(limit.saturating_mul(32))) {
        Ok(Some(root)) => root,
        Ok(None) => return sdk::err_invalid("empty XML document"),
        Err(e) => return sdk::err_invalid(&e),
    };

    let (feed, items) = normalize_feed(&root, limit);
    sdk::ok_data(&json!({ "feed": feed, "items": items }).to_string())
}

fn parse_tree(text: &str, trim_text: bool, max_nodes: usize) -> Result<Option<Node>, String> {
    let mut reader = Reader::from_str(text);
    reader.config_mut().trim_text(false);

    let mut stack: Vec<Node> = Vec::new();
    let mut root: Option<Node> = None;
    let mut count = 0usize;

    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                count += 1;
                if count > max_nodes {
                    return Err(format!("node limit exceeded: {}", max_nodes));
                }
                stack.push(Node::new(
                    name_of(e.name().as_ref()),
                    attributes_of(&reader, &e),
                ));
            }
            Ok(Event::Empty(e)) => {
                count += 1;
                if count > max_nodes {
                    return Err(format!("node limit exceeded: {}", max_nodes));
                }
                attach_node(
                    &mut stack,
                    &mut root,
                    Node::new(name_of(e.name().as_ref()), attributes_of(&reader, &e)),
                );
            }
            Ok(Event::End(_)) => {
                if let Some(node) = stack.pop() {
                    attach_node(&mut stack, &mut root, node);
                }
            }
            Ok(Event::Text(e)) => {
                if let Some(top) = stack.last_mut() {
                    let s = e.decode().map(|c| c.into_owned()).unwrap_or_default();
                    append_text(&mut top.text, &s, trim_text);
                }
            }
            Ok(Event::CData(e)) => {
                if let Some(top) = stack.last_mut() {
                    let s = e.decode().map(|c| c.into_owned()).unwrap_or_default();
                    append_text(&mut top.text, &s, trim_text);
                }
            }
            Ok(Event::GeneralRef(e)) => {
                if let Some(top) = stack.last_mut() {
                    let name = e.decode().map(|c| c.into_owned()).unwrap_or_default();
                    let s = resolve_entity(&name);
                    append_raw(&mut top.text, &s);
                }
            }
            Ok(Event::Eof) => break,
            Err(e) => return Err(format!("XML parse error: {}", e)),
            _ => {}
        }
    }

    if !stack.is_empty() {
        return Err("unclosed XML element".to_string());
    }
    Ok(root)
}

fn attach_node(stack: &mut [Node], root: &mut Option<Node>, node: Node) {
    if let Some(parent) = stack.last_mut() {
        parent.children.push(node);
    } else if root.is_none() {
        *root = Some(node);
    }
}

fn append_text(target: &mut String, text: &str, trim: bool) {
    if text.is_empty() || (trim && text.trim().is_empty()) {
        return;
    }
    if should_insert_space(target, text) {
        target.push(' ');
    }
    target.push_str(text);
}

fn append_raw(target: &mut String, text: &str) {
    if !text.is_empty() {
        target.push_str(text);
    }
}

fn should_insert_space(target: &str, next: &str) -> bool {
    if target.is_empty() {
        return false;
    }
    let last = target.chars().last().unwrap_or(' ');
    let first = next.chars().next().unwrap_or(' ');
    if last.is_whitespace() || first.is_whitespace() {
        return false;
    }
    if matches!(last, '<' | '/' | '&' | '(' | '[' | '{' | '"' | '\'') {
        return false;
    }
    if matches!(
        first,
        '>' | '/' | '&' | ')' | ']' | '}' | ',' | '.' | ':' | ';' | '?' | '!' | '"' | '\''
    ) {
        return false;
    }
    true
}

fn name_of(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn attributes_of(reader: &Reader<&[u8]>, e: &BytesStart<'_>) -> Map<String, Value> {
    let mut out = Map::new();
    for attr in e.attributes().flatten() {
        let key = name_of(attr.key.as_ref());
        let val = attr
            .decoded_and_normalized_value(XmlVersion::Implicit1_0, reader.decoder())
            .map(|c| c.into_owned())
            .unwrap_or_default();
        out.insert(key, json!(val));
    }
    out
}

fn resolve_entity(name: &str) -> String {
    match name {
        "amp" => "&".to_string(),
        "lt" => "<".to_string(),
        "gt" => ">".to_string(),
        "quot" => "\"".to_string(),
        "apos" => "'".to_string(),
        n if n.starts_with("#x") => u32::from_str_radix(&n[2..], 16)
            .ok()
            .and_then(char::from_u32)
            .map(|c| c.to_string())
            .unwrap_or_else(|| format!("&{};", name)),
        n if n.starts_with('#') => n[1..]
            .parse::<u32>()
            .ok()
            .and_then(char::from_u32)
            .map(|c| c.to_string())
            .unwrap_or_else(|| format!("&{};", name)),
        _ => format!("&{};", name),
    }
}

fn normalize_feed(root: &Node, limit: usize) -> (Value, Vec<Value>) {
    if local_name(&root.name) == "feed" {
        normalize_atom(root, limit)
    } else {
        normalize_rss(root, limit)
    }
}

fn normalize_rss(root: &Node, limit: usize) -> (Value, Vec<Value>) {
    let channel = child(root, "channel").unwrap_or(root);
    let feed = json!({
        "title": child_text(channel, "title"),
        "link": child_text(channel, "link"),
        "description": child_text(channel, "description"),
        "updated": first_non_empty(&[
            child_text(channel, "lastBuildDate"),
            child_text(channel, "pubDate"),
        ]),
    });
    let items = children(channel, "item")
        .into_iter()
        .take(limit)
        .map(|item| {
            json!({
                "title": child_text(item, "title"),
                "link": child_text(item, "link"),
                "guid": child_text(item, "guid"),
                "description": child_text(item, "description"),
                "pubDate": child_text(item, "pubDate"),
                "author": first_non_empty(&[
                    child_text(item, "author"),
                    child_text(item, "dc:creator"),
                    child_text(item, "creator"),
                ]),
                "categories": children(item, "category").into_iter().map(|c| c.text.clone()).collect::<Vec<_>>(),
            })
        })
        .collect();
    (feed, items)
}

fn normalize_atom(root: &Node, limit: usize) -> (Value, Vec<Value>) {
    let feed = json!({
        "title": child_text(root, "title"),
        "link": atom_link(root),
        "description": child_text(root, "subtitle"),
        "updated": child_text(root, "updated"),
    });
    let items = children(root, "entry")
        .into_iter()
        .take(limit)
        .map(|entry| {
            json!({
                "title": child_text(entry, "title"),
                "link": atom_link(entry),
                "guid": child_text(entry, "id"),
                "description": first_non_empty(&[
                    child_text(entry, "summary"),
                    child_text(entry, "content"),
                ]),
                "pubDate": first_non_empty(&[
                    child_text(entry, "published"),
                    child_text(entry, "updated"),
                ]),
                "author": child(entry, "author").map(|a| child_text(a, "name")).unwrap_or_default(),
                "categories": children(entry, "category")
                    .into_iter()
                    .filter_map(|c| c.attributes.get("term").and_then(Value::as_str).map(str::to_string))
                    .collect::<Vec<_>>(),
            })
        })
        .collect();
    (feed, items)
}

fn child<'a>(node: &'a Node, name: &str) -> Option<&'a Node> {
    node.children
        .iter()
        .find(|c| local_name(&c.name) == local_name(name))
}

fn children<'a>(node: &'a Node, name: &str) -> Vec<&'a Node> {
    node.children
        .iter()
        .filter(|c| local_name(&c.name) == local_name(name))
        .collect()
}

fn child_text(node: &Node, name: &str) -> String {
    child(node, name)
        .map(|c| c.text.clone())
        .unwrap_or_default()
}

fn first_non_empty(values: &[String]) -> String {
    values
        .iter()
        .find(|s| !s.is_empty())
        .cloned()
        .unwrap_or_default()
}

fn atom_link(node: &Node) -> String {
    for link in children(node, "link") {
        let rel = link
            .attributes
            .get("rel")
            .and_then(Value::as_str)
            .unwrap_or("alternate");
        if rel == "alternate" || rel.is_empty() {
            if let Some(href) = link.attributes.get("href").and_then(Value::as_str) {
                return href.to_string();
            }
            if !link.text.is_empty() {
                return link.text.clone();
            }
        }
    }
    String::new()
}

fn local_name(name: &str) -> &str {
    name.rsplit(':').next().unwrap_or(name)
}

sdk::export_plugin!(handle);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tree_with_attributes_and_text() {
        let root = parse_tree(
            r#"<root><item id="1">hello &amp; world</item></root>"#,
            true,
            10,
        )
        .unwrap()
        .unwrap();
        assert_eq!(root.name, "root");
        assert_eq!(root.children[0].name, "item");
        assert_eq!(root.children[0].attributes["id"], json!("1"));
        assert_eq!(root.children[0].text, "hello & world");
    }

    #[test]
    fn normalizes_rss_items() {
        let root = parse_tree(
            r#"<rss><channel><title>36Kr</title><link>https://36kr.com</link>
            <item><title>A</title><link>https://e/a</link><guid>g1</guid>
            <description>desc</description><pubDate>Mon, 06 Jul 2026 03:56:56 GMT</pubDate>
            <category>AI</category></item></channel></rss>"#,
            true,
            50,
        )
        .unwrap()
        .unwrap();
        let (feed, items) = normalize_feed(&root, 10);
        assert_eq!(feed["title"], json!("36Kr"));
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["title"], json!("A"));
        assert_eq!(items[0]["categories"], json!(["AI"]));
    }

    #[test]
    fn normalizes_atom_entries() {
        let root = parse_tree(
            r#"<feed><title>Feed</title><link href="https://example.com"/>
            <entry><title>Entry</title><id>urn:1</id><link href="https://example.com/1"/>
            <updated>2026-07-06T03:00:00Z</updated><summary>summary</summary>
            <author><name>Ada</name></author><category term="Tech"/></entry></feed>"#,
            true,
            50,
        )
        .unwrap()
        .unwrap();
        let (feed, items) = normalize_feed(&root, 10);
        assert_eq!(feed["link"], json!("https://example.com"));
        assert_eq!(items[0]["link"], json!("https://example.com/1"));
        assert_eq!(items[0]["author"], json!("Ada"));
        assert_eq!(items[0]["categories"], json!(["Tech"]));
    }
}
