# Contributing

`aglet-plugins` holds plugins for [Aglet](https://aglet.dev) — sandboxed extensions
apps depend on via `manifest.requires`. Each plugin is a directory with an
`aplugin.json` manifest + source (Zig / Rust / C++ via emscripten → WebAssembly).

## Workflow

1. Fork + branch.
2. `zig build <plugin>` to build the wasm artifact into `<plugin>/dist/`.
3. Validate `aplugin.json` (id, namespace, actions, backend, version, license, description).
4. Open a PR — CI builds the changed plugins.
5. Publish: tag `<id>-v<version>` → the publish workflow opens a PR to
   [`aglet-registry`](https://github.com/aglet-dev/registry).

Bump the version in **both** `aplugin.json` and the plugin's build manifest
(`Cargo.toml` / `build.zig.zon`) so they never drift.

## License

By contributing you agree your contribution is licensed under MIT.
