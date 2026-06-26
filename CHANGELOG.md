# Changelog

## 0.1.0

Inaugural public release. 7 plugins — 6 WebAssembly (sandboxed, cross-platform)
+ 1 native stdio:

| Plugin | Version | Kind | What it does |
|--------|---------|------|--------------|
| `tokstat` | 0.2.0 | stdio (darwin) | Claude + Codex token usage — ships with the `tokstat` app |
| `crypto` | 0.1.3 | wasm | libsodium: hash / hmac / KDF / encrypt / Ed25519 sign / random |
| `archive` | 0.1.2 | wasm | zip / tar read + write |
| `highlight` | 0.2.0 | wasm | syntax highlighting |
| `markdown` | 0.2.0 | wasm | Markdown → canonical UI IR |
| `image` | 0.1.1 | wasm | image encode / decode / metadata |
| `barcode` | 0.1.1 | wasm | barcode & QR encode / decode |

`tokstat` publishes to the registry with the `tokstat` app in 0.1.0. The wasm
plugins publish when an app that requires them ships. `sysmon` (stdio, macOS) is
deferred to a later release.
