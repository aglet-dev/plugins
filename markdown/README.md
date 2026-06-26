# Markdown plugin (`markdown`)

Render Markdown to Aglet's canonical UI IR.

- **Namespace:** `markdown` · **Version:** 0.2.0 · **Backend:** wasm
- **Actions:** `markdown.render`

## Use from an app

Declare the dependency in your `aglet.json`, then call it from `scripts.js`:

```json
"requires": [{ "plugin": "markdown", "range": ">=0.2.0" }]
```
```js
const r = await markdown.render(APP_ID, { /* params */ });
```

Installs automatically with any app that requires it (from `registry.aglet.dev`).

## License

MIT — see the repo [LICENSE](../LICENSE).
