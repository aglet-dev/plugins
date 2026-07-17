# Changelog

## Unreleased

- **Add `sysmon`** (stdio, macOS) — host system metrics: CPU, memory, disk,
  battery, GPU, temperature, fan, and network throughput. Long-lived native
  subprocess that holds prior-tick state for delta-based sampling. `snapshot`
  returns everything; individual actions (`cpu`, `memory`, `network`, …) return
  one section. Network rate is read via `sysctl(NET_RT_IFLIST2)` (the byte
  counters `getifaddrs` exposes are unreliable on macOS); per-second rate plus a
  monotonic session total. Powers the `netspeed` menu-bar widget.
- **Add `xml`** (wasm) — a pure Rust XML utility plugin. `xml.parse` returns a
  lightweight element tree; `xml.rss` normalizes RSS 2.0 and Atom feeds into
  feed metadata plus item arrays for reader-style aglets.
- **Add `aicreds`** (stdio, darwin) — a read-only credential reader: returns the
  live OAuth access token for Claude Code (`Claude Code-credentials` Keychain) and
  Codex (`~/.codex/auth.json`). Single action `read({provider})`. Makes no network
  calls of its own.
- **Remove `tokstat`** — its Claude/Codex usage probing (HTTP + the slow PTY/JSONL
  fallbacks) moved into the `tokstat` app's `scripts.js`, which now calls the usage
  APIs directly using a token from `aicreds`. Only the OS-privileged credential read
  stays in a plugin. The already-published `tokstat` plugin versions remain in the
  registry (immutable) but are deprecated and no longer referenced by any app.

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
plugins publish when an app that requires them ships. `sysmon` (stdio, macOS)
publishes with the `netspeed` app.
