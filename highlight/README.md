# Syntax Highlight plugin (`highlight`)

Syntax highlighting via tree-sitter — code → IR rich-text runs (renderer-agnostic).

- **Namespace:** `highlight` · **Version:** 0.2.0 · **Backend:** wasm
- **Actions:** `highlight.render`

## Use from an app

Declare the dependency in your `aglet.json`, then call it from `scripts.js`:

```json
"requires": [{ "plugin": "highlight", "range": ">=0.2.0" }]
```
```js
const r = await highlight.render(APP_ID, { /* params */ });
```

Installs automatically with any app that requires it (from `registry.aglet.dev`).

## License

MIT — see the repo [LICENSE](../LICENSE).
