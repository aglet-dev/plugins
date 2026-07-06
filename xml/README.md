# XML plugin (`xml`)

- **Namespace:** `xml` · **Version:** 0.1.0 · **Backend:** wasm
- **Actions:** `xml.parse` · `xml.rss`

## Use from an aglet

```json
"requires": [{ "plugin": "xml", "range": ">=0.1.0" }]
```

```js
const feed = await ctx.plugins.xml.rss({ text: rssXml, limit: 50 });
```

## Actions

### `parse`

Input:

```json
{ "text": "<rss>...</rss>", "trim_text": true, "max_nodes": 5000 }
```

Output:

```json
{ "root": { "name": "rss", "attributes": {}, "children": [], "text": "" } }
```

### `rss`

Normalizes RSS 2.0 and Atom feeds.

Input:

```json
{ "text": "...", "limit": 100 }
```

Output:

```json
{
  "feed": { "title": "Feed title", "link": "https://example.com" },
  "items": [
    {
      "title": "Story",
      "link": "https://example.com/story",
      "guid": "id",
      "description": "Summary",
      "pubDate": "Mon, 06 Jul 2026 03:56:56 GMT",
      "author": "",
      "categories": []
    }
  ]
}
