//! Aglet plugin SDK — wasm32-wasi.
//!
//! Removes the marshaling boilerplate (alloc/free/dispatch exports, JSON
//! parsing, base64 encoding, error envelopes) shared by every wasm plugin.
//! A complete plugin looks like:
//!
//!     const sdk = @import("aglet_plugin_sdk");
//!
//!     const Handlers = struct {
//!         pub fn hash(p: *sdk.Params) anyerror![]const u8 { ... }
//!         pub fn hmac(p: *sdk.Params) anyerror![]const u8 { ... }
//!     };
//!
//!     comptime { sdk.exportRuntime(); }
//!
//!     export fn dispatch(ap: u32, al: u32, pp: u32, pl: u32) callconv(.c) u64 {
//!         return sdk.runDispatch(Handlers, ap, al, pp, pl);
//!     }
//!
//! ABI contract (host ↔ plugin):
//!   - The plugin exports `alloc(len) -> ptr`, `free(ptr, len)`, and
//!     `dispatch(action_ptr, action_len, params_ptr, params_len) -> u64`.
//!   - `dispatch` returns a packed `(ptr << 32) | len` referring to a buffer
//!     in the plugin's linear memory; the host reads it and then calls `free`.
//!   - The buffer contents are JSON: either `{"ok":true, ...}` or
//!     `{"ok":false, "error":{"code","message"}}`. Binary payloads are
//!     standard-base64 strings under `<key>_b64` field names.

const std = @import("std");

// ─── allocator + runtime exports ──────────────────────────────────────────
//
// Single global page allocator for host-visible buffers. wasm has no threads,
// so single-threaded allocation is sufficient.

pub const allocator = std.heap.wasm_allocator;

pub fn alloc(n: u32) callconv(.c) u32 {
    const len = if (n == 0) 1 else n;
    const buf = allocator.alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(buf.ptr));
}

pub fn free(p: u32, n: u32) callconv(.c) void {
    if (p == 0) return;
    const ptr: [*]u8 = @ptrFromInt(p);
    allocator.free(ptr[0..@max(n, 1)]);
}

/// Re-export `alloc` + `free` from this SDK module into the plugin's wasm
/// binary. Call once from a top-level `comptime` block in your wrapper.zig:
///
///     comptime { sdk.exportRuntime(); }
pub fn exportRuntime() void {
    @export(&alloc, .{ .name = "alloc" });
    @export(&free, .{ .name = "free" });
}

// ─── Params: typed input reader ───────────────────────────────────────────

pub const Params = struct {
    arena: std.mem.Allocator,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Params) void {
        self.parsed.deinit();
    }

    /// String field — null if missing or wrong type.
    pub fn str(self: Params, key: []const u8) ?[]const u8 {
        if (self.parsed.value != .object) return null;
        const v = self.parsed.value.object.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    /// Integer field — coerces float; falls back to default if missing or non-numeric.
    pub fn int(self: Params, key: []const u8, default: i64) i64 {
        if (self.parsed.value != .object) return default;
        const v = self.parsed.value.object.get(key) orelse return default;
        return switch (v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => default,
        };
    }

    /// Boolean field — null if missing or non-bool.
    pub fn boolean(self: Params, key: []const u8) ?bool {
        if (self.parsed.value != .object) return null;
        const v = self.parsed.value.object.get(key) orelse return null;
        return if (v == .bool) v.bool else null;
    }

    /// base64-decoded bytes from `<key>` field. Errors on missing or bad b64.
    pub fn bytes(self: Params, key: []const u8) ![]u8 {
        const s = self.str(key) orelse return error.MissingParam;
        return decodeB64(self.arena, s);
    }

    /// Same as `bytes` but returns null if missing (still errors on bad b64).
    pub fn optBytes(self: Params, key: []const u8) !?[]u8 {
        const s = self.str(key) orelse return null;
        return try decodeB64(self.arena, s);
    }
};

/// Parse host-provided JSON params into a typed reader. Returned Params
/// keeps a reference to the parsed JSON tree; caller must `deinit`.
pub fn parseParams(arena: std.mem.Allocator, json: []const u8) !Params {
    return .{
        .arena = arena,
        .parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{}),
    };
}

// ─── Result builders ──────────────────────────────────────────────────────
//
// All builders allocate from the supplied arena and produce the canonical
// success envelope `{"ok":true,"data":{ ... }}`. Fields land inside `data`
// so that the host's JS bridge (which returns `resp.data` to the caller)
// surfaces them at the expected shape.
//
// Binary payloads should use `<key>_b64` field names and be encoded with
// `sdk.encodeB64` / `okBytes`.

pub fn okBytes(arena: std.mem.Allocator, key: []const u8, raw: []const u8) ![]const u8 {
    const b64 = try encodeB64(arena, raw);
    return std.fmt.allocPrint(arena,
        "{{\"ok\":true,\"data\":{{\"{s}\":\"{s}\"}}}}", .{ key, b64 });
}

pub fn okStr(arena: std.mem.Allocator, key: []const u8, s: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        "{{\"ok\":true,\"data\":{{\"{s}\":\"{s}\"}}}}", .{ key, s });
}

pub fn okBool(arena: std.mem.Allocator, key: []const u8, b: bool) ![]const u8 {
    return std.fmt.allocPrint(arena,
        "{{\"ok\":true,\"data\":{{\"{s}\":{s}}}}}", .{ key, if (b) "true" else "false" });
}

pub fn okInt(arena: std.mem.Allocator, key: []const u8, i: i64) ![]const u8 {
    return std.fmt.allocPrint(arena,
        "{{\"ok\":true,\"data\":{{\"{s}\":{d}}}}}", .{ key, i });
}

/// Multi-field result wrapped in the canonical `{ok:true,data:{...}}` envelope.
/// Field names come from the struct field names; values are serialized by
/// Zig type:
///   `[]const u8` / `[]u8` → JSON string
///   `bool` → true/false literal
///   integer / float → numeric literal
///
/// Encode binary data to base64 before passing:
///     return sdk.ok(p.arena, .{
///         .ciphertext_b64 = try sdk.encodeB64(p.arena, &ct),
///         .nonce_b64 = try sdk.encodeB64(p.arena, &nonce),
///     });
pub fn ok(arena: std.mem.Allocator, fields: anytype) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    try buf.appendSlice(arena, "{\"ok\":true,\"data\":{");
    var first = true;
    inline for (std.meta.fields(@TypeOf(fields))) |f| {
        if (first) {
            first = false;
        } else {
            try buf.append(arena, ',');
        }
        try buf.append(arena, '"');
        try buf.appendSlice(arena, f.name);
        try buf.appendSlice(arena, "\":");
        const v = @field(fields, f.name);
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    try buf.append(arena, '"');
                    try buf.appendSlice(arena, v);
                    try buf.append(arena, '"');
                } else @compileError("sdk.ok: unsupported pointer type for field '" ++ f.name ++ "'");
            },
            .bool => try buf.appendSlice(arena, if (v) "true" else "false"),
            .int, .comptime_int => {
                var w = buf.writer(arena);
                try w.print("{d}", .{v});
            },
            .float, .comptime_float => {
                var w = buf.writer(arena);
                try w.print("{d}", .{v});
            },
            else => @compileError("sdk.ok: unsupported type for field '" ++ f.name ++ "': " ++ @typeName(T)),
        }
    }
    try buf.appendSlice(arena, "}}");
    return try arena.dupe(u8, buf.items);
}

// ─── Error envelopes ──────────────────────────────────────────────────────

pub fn err(arena: std.mem.Allocator, code: []const u8, msg: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        "{{\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}",
        .{ code, msg });
}

pub fn errInvalid(arena: std.mem.Allocator, msg: []const u8) ![]const u8 {
    return err(arena, "INVALID_PARAMS", msg);
}

pub fn errUnknown(arena: std.mem.Allocator, action: []const u8) ![]const u8 {
    return err(arena, "UNKNOWN_ACTION", action);
}

// ─── base64 helpers ───────────────────────────────────────────────────────

pub fn decodeB64(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = try dec.calcSizeForSlice(s);
    const out = try arena.alloc(u8, n);
    try dec.decode(out, s);
    return out;
}

pub fn encodeB64(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const n = enc.calcSize(bytes.len);
    const out = try arena.alloc(u8, n);
    return enc.encode(out, bytes);
}

// ─── Dispatch runner ──────────────────────────────────────────────────────
//
// `Handlers` is a struct type whose pub fn decls are action handlers:
//
//     fn <action_name>(p: *Params) anyerror![]const u8
//
// runDispatch:
//   1. Materializes action/params slices from (ptr, len) pairs
//   2. Parses params JSON once
//   3. Comptime-expands the handlers' decls into a switch
//   4. Returns errored / unknown action as JSON envelope
//   5. Copies result into a persistent buffer the host frees later
//
// Caller's wrapper.zig:
//     export fn dispatch(ap: u32, al: u32, pp: u32, pl: u32) callconv(.c) u64 {
//         return sdk.runDispatch(Handlers, ap, al, pp, pl);
//     }

pub fn runDispatch(comptime Handlers: type, ap: u32, al: u32, pp: u32, pl: u32) u64 {
    const action = mkSlice(ap, al);
    const params = mkSlice(pp, pl);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = dispatchInner(Handlers, a, action, params) catch |e|
        err(a, "INTERNAL", @errorName(e)) catch return 0;

    const buf = allocator.alloc(u8, if (out.len == 0) 1 else out.len) catch return 0;
    @memcpy(buf[0..out.len], out);
    return (@as(u64, @intCast(@intFromPtr(buf.ptr))) << 32) | @as(u64, @intCast(out.len));
}

fn dispatchInner(comptime Handlers: type, a: std.mem.Allocator, action: []const u8, params_json: []const u8) ![]const u8 {
    var p = parseParams(a, params_json) catch {
        return errInvalid(a, "params is not valid JSON");
    };
    defer p.deinit();
    const decls = comptime std.meta.declarations(Handlers);
    inline for (decls) |decl| {
        if (std.mem.eql(u8, decl.name, action)) {
            return @field(Handlers, decl.name)(&p);
        }
    }
    return errUnknown(a, action);
}

fn mkSlice(p: u32, n: u32) []const u8 {
    if (n == 0) return &[_]u8{};
    const ptr: [*]const u8 = @ptrFromInt(p);
    return ptr[0..n];
}
