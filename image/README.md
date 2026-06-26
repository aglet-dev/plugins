# Image plugin (`image`)

Image encode / decode / metadata (libwebp, stb).

- **Namespace:** `image` · **Version:** 0.1.1 · **Backend:** wasm
- **Actions:** `image.metadata` · `image.decode` · `image.encode` · `image.process`

## Use from an app

Declare the dependency in your `aglet.json`, then call it from `scripts.js`:

```json
"requires": [{ "plugin": "image", "range": ">=0.1.1" }]
```
```js
const r = await image.metadata(APP_ID, { /* params */ });
```

Installs automatically with any app that requires it (from `registry.aglet.dev`).

## License

MIT — see the repo [LICENSE](../LICENSE).
