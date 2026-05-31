# aglet-plugins

Community wasm plugins for [Aglet](https://github.com/agent-rt/aglet). A
plugin is a pure-compute capability exposed to aglets via
`manifest.requires[]`. Built with emscripten, sandboxed with wasmtime.

Published to [aglet-registry](https://github.com/agent-rt/aglet-registry)
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
[PLUGINS.md](https://github.com/agent-rt/aglet-registry/blob/main/PLUGINS.md)
for the wasm ABI and `meta.json` schema.

Required exports: `alloc`, `free`, `dispatch`, `memory`. Imports limited
to `env.emscripten_notify_memory_growth` and three WASI stubs
(`fd_close`, `fd_write`, `fd_seek`). Anything else needs review — see
[REVIEW_PROCESS.md Step 6](https://github.com/agent-rt/aglet-registry/blob/main/REVIEW_PROCESS.md).

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
| `barcode` | barcode | encode, decode | [zxing-cpp](https://github.com/zxing-cpp/zxing-cpp) |
| `image` | image | metadata, decode, encode, process | [libwebp](https://github.com/webmproject/libwebp) + [stb](https://github.com/nothings/stb) |
| `archive` | archive | list, extract, create | [libarchive](https://github.com/libarchive/libarchive) |
| `crypto` | crypto | hash, hmac, kdf, encrypt, decrypt, keypair, sign, verify, random | zig stdlib (no native deps) |

## License

MIT.
