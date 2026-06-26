//! Build entry for community wasm plugins.
//!
//!   zig build           # build everything
//!   zig build barcode   # one plugin
//!
//! Most plugins keep CMakeLists.txt + emscripten (zxing-cpp throws,
//! libwebp/libarchive have nontrivial CMake configs). The `crypto` plugin
//! is pure zig wasm32-wasi using std.crypto — no emscripten.
//!
//! CMake-style plugins require emcc / emcmake in PATH.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const all = b.step("all", "Build every plugin");
    b.default_step.dependOn(all);

    // ── CMake + emscripten plugins ─────────────────────────────────────────
    const zxing = b.dependency("zxing_cpp", .{}).path("");
    const webp = b.dependency("libwebp", .{}).path("");
    const archive_dep = b.dependency("libarchive", .{}).path("");
    const xz_dep = b.dependency("xz", .{}).path("");
    const zstd_dep = b.dependency("zstd", .{}).path("");

    all.dependOn(addCmakePlugin(b, .{ .id = "barcode", .deps = &.{
        .{ .env = "ZXING_CPP_ROOT", .path = zxing },
    } }));
    all.dependOn(addCmakePlugin(b, .{ .id = "image", .deps = &.{
        .{ .env = "LIBWEBP_ROOT", .path = webp },
    } }));
    all.dependOn(addCmakePlugin(b, .{ .id = "archive", .deps = &.{
        .{ .env = "LIBARCHIVE_ROOT", .path = archive_dep },
        .{ .env = "XZ_ROOT", .path = xz_dep },
        .{ .env = "ZSTD_ROOT", .path = zstd_dep },
    } }));

    // ── Pure-zig plugins (wasm32-wasi via std.crypto / stdlib) ─────────────
    all.dependOn(addZigPlugin(b, "crypto"));

    // ── Rust plugins (wasm32-wasip1，C 依赖经 zig cc 编) ────────────────────
    all.dependOn(addRustPlugin(b, "highlight"));
    all.dependOn(addRustPlugin(b, "markdown")); // comrak → IR node 树（pure Rust，无 C）

    // ── stdio native 插件(per-platform 二进制)─────────────────────────────
    // tokstat 随 tokstat app 0.1.0 发布(darwin)。sysmon 待后续。
    all.dependOn(addStdioNativePlugin(b, "tokstat"));
}

const CmakeDep = struct {
    env: []const u8,
    path: std.Build.LazyPath,
};

const CmakeSpec = struct {
    id: []const u8,
    /// Env vars to set when invoking `emcmake cmake -S <id>`. Each entry
    /// gets `<env>=<resolved path>` so the CMakeLists can `$ENV{<env>}` it.
    /// Used for vendoring sibling-source dependencies (libarchive needs
    /// LIBARCHIVE_ROOT + XZ_ROOT + ZSTD_ROOT, others typically need one).
    deps: []const CmakeDep,
};

fn addCmakePlugin(b: *std.Build, spec: CmakeSpec) *std.Build.Step {
    const dist_rel = b.fmt("{s}/dist", .{spec.id});
    const cache_rel = b.fmt("{s}/build", .{spec.id});

    const configure = b.addSystemCommand(&.{ "emcmake", "cmake", "-S", b.pathFromRoot(spec.id), "-B" });
    configure.addArg(b.pathFromRoot(cache_rel));
    configure.addArg("-DCMAKE_BUILD_TYPE=Release");
    for (spec.deps) |d| {
        configure.setEnvironmentVariable(d.env, d.path.getPath3(b, null).toString(b.allocator) catch @panic("OOM"));
    }

    const build_cmd = b.addSystemCommand(&.{ "cmake", "--build" });
    build_cmd.addArg(b.pathFromRoot(cache_rel));
    build_cmd.addArg("-j");
    build_cmd.step.dependOn(&configure.step);

    const stage = b.addSystemCommand(&.{ "sh", "-c" });
    stage.addArg(b.fmt(
        \\set -e
        \\mkdir -p {s}
        \\cp {s}/{s}.wasm {s}/{s}.wasm
    , .{
        b.pathFromRoot(dist_rel),
        b.pathFromRoot(cache_rel),
        spec.id,
        b.pathFromRoot(dist_rel),
        spec.id,
    }));
    stage.step.dependOn(&build_cmd.step);

    const step = b.step(spec.id, b.fmt("Build {s}/dist/{s}.wasm", .{ spec.id, spec.id }));
    step.dependOn(&stage.step);
    return step;
}

/// Build `<id>/` (a Rust cdylib) to wasm32-wasip1, stage to `<id>/dist/<id>.wasm`.
/// C 依赖（tree-sitter grammar 等）经 `.cargo-cc/zig-wasi-cc`（包 `zig cc`，自带
/// wasi-libc，关 ubsan）编译——免装 wasi-sdk。需 `cargo` + wasm32-wasip1 target +
/// `zig` 在 PATH。host 侧支持见 wasm_runtime.zig（agl_free 回退 + environ stub）。
fn addRustPlugin(b: *std.Build, id: []const u8) *std.Build.Step {
    const dir = b.pathFromRoot(id);
    const cc = b.pathFromRoot(b.fmt("{s}/.cargo-cc/zig-wasi-cc", .{id}));
    const ar = b.pathFromRoot(b.fmt("{s}/.cargo-cc/zig-ar", .{id}));

    const build_cmd = b.addSystemCommand(&.{ "cargo", "build", "--release", "--target", "wasm32-wasip1" });
    build_cmd.setCwd(.{ .cwd_relative = dir });
    build_cmd.setEnvironmentVariable("CC_wasm32_wasip1", cc);
    build_cmd.setEnvironmentVariable("AR_wasm32_wasip1", ar);
    build_cmd.setEnvironmentVariable("CRATE_CC_NO_DEFAULTS", "1");

    const stage = b.addSystemCommand(&.{ "sh", "-c" });
    stage.addArg(b.fmt(
        \\set -e
        \\mkdir -p {s}/dist
        \\cp {s}/target/wasm32-wasip1/release/{s}.wasm {s}/dist/{s}.wasm
    , .{ dir, dir, id, dir, id }));
    stage.step.dependOn(&build_cmd.step);

    const step = b.step(id, b.fmt("Build {s}/dist/{s}.wasm (rust/tree-sitter)", .{ id, id }));
    step.dependOn(&stage.step);
    return step;
}

fn addZigPlugin(b: *std.Build, id: []const u8) *std.Build.Step {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    // SDK module — shared across all Zig wasm plugins in this repo. Each
    // plugin imports it as `@import("aglet_plugin_sdk")` for the marshaling
    // helpers + dispatch runner.
    const sdk_mod = b.createModule(.{
        .root_source_file = b.path("sdk/zig/plugin.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("{s}/src/wrapper.zig", .{id})),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "aglet_plugin_sdk", .module = sdk_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = id,
        .root_module = mod,
    });
    exe.entry = .disabled;
    exe.rdynamic = true;

    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("../{s}/dist", .{id}) } },
    });

    const step = b.step(id, b.fmt("Build {s}/dist/{s}.wasm", .{ id, id }));
    step.dependOn(&install.step);
    return step;
}

/// Canonical `<os>-<arch>` target token — MUST match aglet core
/// `src/core/plugin_target.zig` (pack/install/loader use the same vocab).
fn targetString(b: *std.Build, t: std.Target) []const u8 {
    const os = switch (t.os.tag) {
        .macos => "darwin",
        .windows => "windows",
        .linux => "linux",
        else => "unknown",
    };
    const arch = switch (t.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => "unknown",
    };
    return b.fmt("{s}-{s}", .{ os, arch });
}

/// Build `<id>/src/main.zig` as a native executable under
/// `<id>/dist/<id>-<os>-<arch>`. stdio plugins are per-platform native binaries
/// spawned as subprocesses; the `.aplugin` carries one per declared target and
/// the host picks the matching one (see aglet docs/STDIO_PLUGIN_SPEC.md +
/// PLUGINS.md). Built for the host target (no cross-compile here — CI on each
/// runner OS produces its target's binary; future: a build matrix). Links libc
/// for platform syscalls (Mach API on macOS, /proc on Linux).
fn addStdioNativePlugin(b: *std.Build, id: []const u8) *std.Build.Step {
    const target = b.graph.host;
    const mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("{s}/src/main.zig", .{id})),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    mod.link_libc = true;
    const exe = b.addExecutable(.{
        .name = id,
        .root_module = mod,
    });
    // macOS: sysmon 的 battery(IOKit IOPS) / gpu(IORegistry) 走 IOKit +
    // CoreFoundation。两者系统自带，给所有 stdio plugin 链上无害。
    if (target.result.os.tag == .macos) {
        mod.linkFramework("IOKit", .{});
        mod.linkFramework("CoreFoundation", .{});
    }

    // dist/<id>-<os>-<arch> —— per-target naming so multiple platforms coexist
    // in one .aplugin. aplugin.json backend.path is the base `dist/<id>`.
    const tname = b.fmt("{s}-{s}", .{ id, targetString(b, target.result) });
    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("../{s}/dist", .{id}) } },
        .dest_sub_path = tname,
    });

    const step = b.step(id, b.fmt("Build {s}/dist/{s} (native stdio plugin)", .{ id, tname }));
    step.dependOn(&install.step);
    return step;
}
