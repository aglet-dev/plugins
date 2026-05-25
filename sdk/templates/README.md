# Plugin scaffolding templates

Starter sources for new wasm plugins. Two flavors:

- **`zig/`** — pure-Zig plugin targeting `wasm32-wasi`. Best for plugins
  whose dependencies are available in zig's stdlib (crypto, encoding,
  small data formats) or as zig packages.
- **`cpp/`** — C++17 plugin built via emscripten. Best for plugins that
  wrap an existing C/C++ library (zxing, libwebp, libarchive, etc.).

## Manual scaffolding

Copy the template directory under the repository root and rename it:

```bash
cp -r sdk/templates/zig my-plugin
cd my-plugin
# Replace placeholders in plugin.json and src/wrapper.*:
#   {{id}}          → my-plugin
#   {{Id}}          → My Plugin
#   {{namespace}}   → my_plugin
#   {{description}} → one-line summary
```

Then register the plugin in the repo's top-level `build.zig`:

- Zig plugin: add `all.dependOn(addZigPlugin(b, "my-plugin"));`
- C++ plugin: see existing `addCmakePlugin` calls for the dependency
  resolution pattern; you'll typically need to add a `b.dependency(...)`
  entry in `build.zig.zon` for any C library you vendor.

## Future tooling

The `aglet plugin new <id>` command in the Aglet CLI consumes these
templates with placeholder substitution. The placeholder names above are
the contract; please don't introduce new ones without updating the CLI.
