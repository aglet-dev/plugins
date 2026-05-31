# aglet-plugin-sdk

Helpers for writing **wasm plugins** for the [Aglet](https://aglet.dev) runtime.

## What this gives you

| Layer | Without SDK | With SDK |
|-------|-------------|----------|
| wasm runtime exports (`alloc` / `free` / `dispatch`) | hand-rolled per plugin (~40 LOC) | `comptime { sdk.exportRuntime(); }` |
| Action dispatch switch | hand-rolled (~10 LOC + 1 per action) | `sdk.runDispatch(Handlers, ...)` (zero-LOC dispatch) |
| Input JSON parsing | hand-rolled getters (~30 LOC) | `p.str("algo")` / `p.bytes("data_b64")` |
| Output envelope | hand-rolled `std.fmt.allocPrint` per result type | `sdk.okBytes(a, "key", &bytes)` / `sdk.ok(a, .{...})` |
| base64 encode/decode | hand-rolled (~10 LOC) | `sdk.encodeB64` / `sdk.decodeB64` |
| Error envelope | hand-rolled per code | `sdk.err(a, code, msg)` / `sdk.errInvalid(a, msg)` |

**Net**: a typical plugin loses ~100 lines of boilerplate.

## Minimal plugin (Zig, wasm32-wasi)

```zig
// my-plugin/src/wrapper.zig
const std = @import("std");
const sdk = @import("aglet_plugin_sdk");

const Handlers = struct {
    pub fn echo(p: *sdk.Params) anyerror![]const u8 {
        const msg = p.str("msg") orelse "(empty)";
        return sdk.okStr(p.arena, "echo", msg);
    }

    pub fn add(p: *sdk.Params) anyerror![]const u8 {
        const a = p.int("a", 0);
        const b = p.int("b", 0);
        return sdk.okInt(p.arena, "sum", a + b);
    }
};

comptime { sdk.exportRuntime(); }

export fn dispatch(ap: u32, al: u32, pp: u32, pl: u32) callconv(.c) u64 {
    return sdk.runDispatch(Handlers, ap, al, pp, pl);
}
```

## Minimal plugin (C++17, emscripten)

```cpp
// my-plugin/src/wrapper.cpp
#include <aglet_plugin.h>
#include <string>
#include <string_view>

static std::string doEcho(const aglet::Params& p) {
    auto msg = p.strOr("msg", "(empty)");
    return aglet::Result::ok().str("echo", msg);
}

static std::string doAdd(const aglet::Params& p) {
    int64_t a = p.integer("a", 0);
    int64_t b = p.integer("b", 0);
    return aglet::Result::ok().integer("sum", a + b);
}

std::string aglet_dispatch_action(std::string_view action,
                                  std::string_view params_json) {
    aglet::Params p(params_json);
    if (action == "echo") return doEcho(p);
    if (action == "add")  return doAdd(p);
    return aglet::errUnknown(action);
}

AGLET_PLUGIN_EXPORTS
```

Pair either source with a `aplugin.json` describing the actions (the host
runtime validates declarations against runtime calls) and you have a
shipping plugin.

## Layout

```
sdk/
├── README.md              # this file
├── plugin.schema.json     # JSON Schema for aplugin.json (draft 2020-12)
├── zig/
│   └── plugin.zig         # Zig SDK — Params / Result / runDispatch / exportRuntime
├── c/
│   ├── aglet_plugin.h     # C++17 header-only SDK — Params / Result / AGLET_PLUGIN_EXPORTS
│   └── CMakeLists.txt     # INTERFACE library aglet_plugin_sdk_c
└── templates/             # scaffolding source for new plugins (see templates/README.md)
    ├── zig/               # Zig wasm32-wasi starter
    └── cpp/               # C++17 emscripten starter
```

## Validating aplugin.json

`plugin.schema.json` is a JSON Schema (draft 2020-12) covering the canonical
manifest shape. Editors that understand JSON Schema (VS Code, JetBrains, etc.)
can pick it up via a `$schema` reference:

```json
{
  "$schema": "../sdk/plugin.schema.json",
  "manifest": { ... }
}
```

Or validate from CI:

```bash
python3 -m pip install jsonschema
python3 -c "import json,jsonschema; jsonschema.validate(json.load(open('aplugin.json')), json.load(open('../sdk/plugin.schema.json')))"
```

The Aglet runtime applies stricter validation at install time (cross-checking
permissions, namespace uniqueness, etc.). This schema is the lighter-weight
check that catches structural mistakes before you build.

## Build integration

**Zig plugins.** The repo-level `build.zig` exposes `addZigPlugin(b, "<id>")`,
which auto-wires `aglet_plugin_sdk` as a module import:

```zig
const sdk = @import("aglet_plugin_sdk");
```

**C/C++ plugins (emscripten).** Add the SDK as a subdirectory in the
plugin's `CMakeLists.txt` and link the INTERFACE target:

```cmake
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../sdk/c
                 ${CMAKE_BINARY_DIR}/aglet_plugin_sdk_c)
target_link_libraries(<plugin> aglet_plugin_sdk_c)
```

Then in source:

```cpp
#include <aglet_plugin.h>
```

## Scope

This SDK is for **sandboxed wasm plugins**, which are the right shape for
community contributions: pure computation, no host APIs. Plugins that need
direct OS access (clipboard, filesystem, camera, system info, etc.) are
shipped as static plugins inside the Aglet runtime itself. They use the
same `aplugin.json` schema but link against the runtime directly, so this
SDK does not apply to them.

## License

MIT (see ../LICENSE)
