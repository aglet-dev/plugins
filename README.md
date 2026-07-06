# aglet-plugins

Community plugins for [Aglet](https://github.com/aglet-dev/aglet). A plugin is a
capability exposed to aglets via `manifest.requires[]`. Most are sandboxed
**WebAssembly** (from Zig / Rust / C++ via emscripten); a few are native
**stdio** subprocess plugins (per-platform binary) where OS access is required.

Published to [aglet-registry](https://github.com/aglet-dev/registry)
under `plugins/<id>/<version>.aplugin`. End users install aglets, not
plugins — dependencies are resolved automatically.

## Layout

```
<id>/
  aplugin.json          # manifest
  src/wrapper.cpp      # source
  CMakeLists.txt       # emscripten build config
  build.sh             # → dist/<id>.wasm
```

`dist/*.wasm` is gitignored; rebuild via `./<id>/build.sh`.

## Plugin format

See
[PLUGINS.md](https://github.com/aglet-dev/registry/blob/main/PLUGINS.md)
for the wasm ABI and `meta.json` schema.

Required exports: `alloc`, `free`, `dispatch`, `memory`. Imports limited
to `env.emscripten_notify_memory_growth` and three WASI stubs
(`fd_close`, `fd_write`, `fd_seek`). Anything else needs review — see
[REVIEW_PROCESS.md Step 6](https://github.com/aglet-dev/registry/blob/main/REVIEW_PROCESS.md).

## Build

```sh
zig build              # all plugins
zig build barcode      # one
```

Deps (zxing-cpp, libwebp) are declared in `build.zig.zon` and fetched
automatically. Requires zig 0.16+ and [emscripten](https://emscripten.org)
(`brew install emscripten`).

## Publish

Tag `<id>-v<version>` and push; CI rebuilds and opens a PR to
aglet-registry.

```sh
git tag barcode-v0.2.0
git push --tags
```

## Plugins

| id | namespace | actions | upstream |
|---|---|---|---|
| `crypto` | crypto | hash, hmac, kdf, encrypt, decrypt, keypair, sign, verify, random | libsodium |
| `archive` | archive | list, extract, create | [libarchive](https://github.com/libarchive/libarchive) |
| `barcode` | barcode | encode, decode | [zxing-cpp](https://github.com/zxing-cpp/zxing-cpp) |
| `image` | image | metadata, decode, encode, process | [libwebp](https://github.com/webmproject/libwebp) + [stb](https://github.com/nothings/stb) |
| `markdown` | markdown | render | Markdown → canonical UI IR |
| `xml` | xml | parse, rss | XML tree parsing + RSS/Atom item extraction |
| `highlight` | highlight | highlight | syntax highlighting (Rust) |
| `aicreds` | aicreds | read | Live OAuth token for Claude Code / Codex — **stdio native** (darwin) |

`aicreds` is a read-only native **stdio** plugin (per-platform binary, macOS). It reads
the auto-refreshed OAuth access token that local AI coding tools keep in the OS keystore
(Claude Code's `Claude Code-credentials` Keychain item; Codex's `~/.codex/auth.json`) and
hands it to a consuming aglet — which then calls the provider usage APIs itself. Reading
another app's credentials is an OS-privileged operation a sandboxed aglet can't do, so it
lives in a small, single-purpose plugin. It makes no network calls of its own. Ships with
the `tokstat` app. (Supersedes the old `tokstat` plugin, which bundled the HTTP/PTY probes;
those moved into the app.) The wasm plugins above publish to the registry when an app that
needs them ships. `sysmon` (stdio, macOS) is deferred to a later release.

## License

MIT.
