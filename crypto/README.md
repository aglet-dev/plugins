# Crypto plugin (`crypto`)

Modern cryptography via libsodium: hash, hmac, KDF, symmetric encrypt, Ed25519 sign, secure random.

- **Namespace:** `crypto` · **Version:** 0.1.3 · **Backend:** wasm
- **Actions:** `crypto.hash` · `crypto.hmac` · `crypto.kdf` · `crypto.encrypt` · `crypto.decrypt` · `crypto.keypair` · `crypto.sign` · `crypto.verify` · `crypto.random` · `crypto.totp`

## Use from an app

Declare the dependency in your `aglet.json`, then call it from `scripts.js`:

```json
"requires": [{ "plugin": "crypto", "range": ">=0.1.3" }]
```
```js
const r = await crypto.hash(APP_ID, { /* params */ });
```

Installs automatically with any app that requires it (from `registry.aglet.dev`).

## License

MIT — see the repo [LICENSE](../LICENSE).
