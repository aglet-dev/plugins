# Archive plugin (`archive`)

Read zip / tar / tar.{gz,bz2,xz,zst} / rar (4 & 5). Write zip / tar / tar.{gz,xz,zst}.

- **Namespace:** `archive` · **Version:** 0.1.2 · **Backend:** wasm
- **Actions:** `archive.list` · `archive.extract` · `archive.create`

## Use from an app

Declare the dependency in your `aglet.json`, then call it from `scripts.js`:

```json
"requires": [{ "plugin": "archive", "range": ">=0.1.2" }]
```
```js
const r = await archive.list(APP_ID, { /* params */ });
```

Installs automatically with any app that requires it (from `registry.aglet.dev`).

## License

MIT — see the repo [LICENSE](../LICENSE).
