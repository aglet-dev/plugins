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
