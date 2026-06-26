# Barcode plugin (`barcode`)

Barcode & QR encode / decode (zxing-cpp).

- **Namespace:** `barcode` · **Version:** 0.1.1 · **Backend:** wasm
- **Actions:** `barcode.encode` · `barcode.decode`

## Use from an app

Declare the dependency in your `aglet.json`, then call it from `scripts.js`:

```json
"requires": [{ "plugin": "barcode", "range": ">=0.1.1" }]
```
```js
const r = await barcode.encode(APP_ID, { /* params */ });
```

Installs automatically with any app that requires it (from `registry.aglet.dev`).

## License

MIT — see the repo [LICENSE](../LICENSE).
