//! aicreds — read the live OAuth access token for local AI coding tools.
//!
//! A read-only stdio MCP plugin. It exists because reading another app's
//! credentials is an OS-privileged operation a sandboxed aglet can't do:
//!   - Claude: the `Claude Code-credentials` Keychain item (auto-refreshed
//!     by Claude Code) → `claudeAiOauth.accessToken`.
//!   - Codex : `~/.codex/auth.json` (plaintext, 0600) → `tokens.access_token`
//!     (+ `account_id`).
//! It returns the fresh token to the caller and makes NO network calls of
//! its own — HTTP + parsing live in the consuming aglet's scripts.js.
//!
//! Protocol: MCP JSON-RPC over stdio (LSP Content-Length framing), one
//! tool `aicreds.read({provider})`. `--check` prints a token-free health
//! line for local verification.
//!
//! macOS-first (Keychain via `security`, codex path under $HOME). Other
//! platforms build once their credential store is wired.

const std = @import("std");
const posix = std.posix;

// ── libc bindings ──────────────────────────────────────────────────────

const stdin_fd: posix.fd_t = 0;
const stdout_fd: posix.fd_t = 1;
const stderr_fd: posix.fd_t = 2;

extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn lseek(fd: c_int, off: c_long, whence: c_int) c_long;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn _exit(status: c_int) noreturn;

const O_RDONLY: c_int = 0;
const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;

// Debug log → stderr. daemon-side stdio_plugin drains it into the aglet
// runtime log (prefix "[plugin:aicreds] ").
fn tlog(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = write(stderr_fd, out.ptr, out.len);
}

// ── LSP-style framing ─────────────────────────────────────────────────

fn readAll(buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try posix.read(stdin_fd, buf[got..]);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
}

fn writeAllStdout(buf: []const u8) !void {
    var sent: usize = 0;
    while (sent < buf.len) {
        const n = write(stdout_fd, buf.ptr + sent, buf.len - sent);
        if (n <= 0) return error.WriteFailed;
        sent += @intCast(n);
    }
}

fn readFramed(alloc: std.mem.Allocator) ![]u8 {
    var header: [512]u8 = undefined;
    var hlen: usize = 0;
    while (true) {
        if (hlen >= header.len) return error.HeaderTooBig;
        try readAll(header[hlen..][0..1]);
        hlen += 1;
        if (hlen >= 4 and std.mem.eql(u8, header[hlen - 4 .. hlen], "\r\n\r\n")) break;
    }
    var length: ?usize = null;
    var it = std.mem.splitSequence(u8, header[0 .. hlen - 4], "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const k = std.mem.trim(u8, line[0..colon], " \t");
        const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(k, "Content-Length")) {
            length = std.fmt.parseInt(usize, v, 10) catch return error.BadHeader;
        }
    }
    const n = length orelse return error.MissingContentLength;
    const body = try alloc.alloc(u8, n);
    errdefer alloc.free(body);
    try readAll(body);
    return body;
}

fn writeFramed(body: []const u8) !void {
    var hdr: [64]u8 = undefined;
    const h = try std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len});
    try writeAllStdout(h);
    try writeAllStdout(body);
}

// ── small JSON helpers ────────────────────────────────────────────────

const Buf = std.ArrayList(u8);

fn jsonString(buf: *Buf, alloc: std.mem.Allocator, s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(alloc, "\\\""),
        '\\' => try buf.appendSlice(alloc, "\\\\"),
        '\n' => try buf.appendSlice(alloc, "\\n"),
        '\r' => try buf.appendSlice(alloc, "\\r"),
        '\t' => try buf.appendSlice(alloc, "\\t"),
        else => if (c < 0x20) {
            var esc: [7]u8 = undefined;
            const w = try std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c});
            try buf.appendSlice(alloc, w);
        } else try buf.append(alloc, c),
    };
    try buf.append(alloc, '"');
}

fn extractStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;
    var i: usize = std.mem.indexOf(u8, json, needle) orelse return null;
    i += needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {}
    if (i >= json.len) return null;
    return json[start..i];
}

fn extractIdRaw(json: []const u8) []const u8 {
    var i: usize = std.mem.indexOf(u8, json, "\"id\"") orelse return "null";
    i += 4;
    while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len) return "null";
    const start = i;
    if (json[i] == '"') {
        i += 1;
        while (i < json.len and json[i] != '"') : (i += 1) {}
        if (i >= json.len) return "null";
        return json[start .. i + 1];
    }
    while (i < json.len and json[i] != ',' and json[i] != '}' and json[i] != ' ') : (i += 1) {}
    return json[start..i];
}

fn writeError(arena: std.mem.Allocator, id: []const u8, code: i32, msg: []const u8) !void {
    var resp: Buf = .empty;
    defer resp.deinit(arena);
    try resp.print(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":", .{ id, code });
    try jsonString(&resp, arena, msg);
    try resp.appendSlice(arena, "}}");
    try writeFramed(resp.items);
}

// ── subprocess + file capture (OS-privileged reads) ───────────────────

fn spawnCaptureStdout(arena: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (argv.len == 0) return error.NoArgv;

    var argv_z = try arena.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |s, i| argv_z[i] = (try arena.dupeZ(u8, s)).ptr;
    argv_z[argv.len] = null;

    var fds: [2]c_int = .{ -1, -1 };
    if (pipe(&fds) != 0) return error.PipeFailed;
    const pid = fork();
    if (pid < 0) {
        _ = close(fds[0]);
        _ = close(fds[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        // child: stdout → pipe, stdin/stderr → /dev/null
        _ = dup2(fds[1], stdout_fd);
        _ = close(fds[0]);
        _ = close(fds[1]);
        const dev_null_z: [*:0]const u8 = "/dev/null";
        const null_fd = open(dev_null_z, O_RDONLY);
        if (null_fd >= 0) {
            _ = dup2(null_fd, stderr_fd);
            _ = dup2(null_fd, stdin_fd);
            _ = close(null_fd);
        }
        const ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv_z.ptr);
        _ = execvp(@ptrCast(argv_z[0].?), ptr);
        _exit(127);
    }
    _ = close(fds[1]);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = read(fds[0], &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(arena, buf[0..@intCast(n)]);
        if (out.items.len > 1024 * 1024) break; // cap 1MB
    }
    _ = close(fds[0]);

    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);

    return out.toOwnedSlice(arena);
}

fn readWholeFile(arena: std.mem.Allocator, path_z: [:0]const u8) ![]u8 {
    const fd = open(path_z.ptr, O_RDONLY);
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    const sz = lseek(fd, 0, SEEK_END);
    if (sz <= 0 or sz > 4 * 1024 * 1024) return error.SizeBad;
    _ = lseek(fd, 0, SEEK_SET);
    const buf = try arena.alloc(u8, @intCast(sz));
    var got: usize = 0;
    while (got < buf.len) {
        const r = read(fd, buf.ptr + got, buf.len - got);
        if (r <= 0) break;
        got += @intCast(r);
    }
    return buf[0..got];
}

// ── credential readers ────────────────────────────────────────────────

/// Claude Code stores its OAuth blob in the macOS Keychain under service
/// "Claude Code-credentials". `security -w` prints the raw password (the
/// JSON blob); first read from a non-Claude-Code binary may prompt a
/// Keychain authorization (user can "Always Allow").
fn readClaudeToken(arena: std.mem.Allocator) ![]const u8 {
    const kc = try spawnCaptureStdout(arena, &.{
        "/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w",
    });
    var parsed = std.json.parseFromSlice(std.json.Value, arena, std.mem.trim(u8, kc, " \t\r\n"), .{}) catch return error.KcParse;
    defer parsed.deinit();
    const root = switch (parsed.value) { .object => |o| o, else => return error.KcShape };
    const oauth = switch (root.get("claudeAiOauth") orelse return error.KcNoOauth) {
        .object => |o| o, else => return error.KcShape,
    };
    const tok = switch (oauth.get("accessToken") orelse return error.KcNoToken) {
        .string => |s| s, else => return error.KcShape,
    };
    return arena.dupe(u8, tok);
}

const CodexCred = struct { access_token: []const u8, account_id: ?[]const u8 };

/// Codex keeps a plaintext `~/.codex/auth.json` (0600) with `tokens.*`.
fn readCodexCred(arena: std.mem.Allocator) !CodexCred {
    const home_cstr = getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_cstr);
    const path = try std.fmt.allocPrintSentinel(arena, "{s}/.codex/auth.json", .{home}, 0);
    const bytes = try readWholeFile(arena, path);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, bytes, .{}) catch return error.AuthParse;
    defer parsed.deinit();
    const root = switch (parsed.value) { .object => |o| o, else => return error.AuthShape };
    const tokens = switch (root.get("tokens") orelse return error.AuthNoTokens) {
        .object => |o| o, else => return error.AuthShape,
    };
    const at = switch (tokens.get("access_token") orelse return error.AuthNoAccess) {
        .string => |s| s, else => return error.AuthShape,
    };
    var acct: ?[]const u8 = null;
    if (tokens.get("account_id")) |v| if (v == .string) {
        acct = arena.dupe(u8, v.string) catch null;
    };
    return .{ .access_token = try arena.dupe(u8, at), .account_id = acct };
}

/// Build the tool result JSON for one provider. Soft failure: an unreadable
/// credential returns `{"access_token":"","error":"<why>"}` (not a JSON-RPC
/// error) so the aglet can surface a "connect" prompt instead of throwing.
fn buildRead(arena: std.mem.Allocator, provider: []const u8) ![]u8 {
    var buf: Buf = .empty;
    if (std.mem.eql(u8, provider, "claude")) {
        const tok = readClaudeToken(arena) catch |e| return errJson(arena, e);
        try buf.append(arena, '{');
        try buf.appendSlice(arena, "\"access_token\":");
        try jsonString(&buf, arena, tok);
        try buf.append(arena, '}');
    } else if (std.mem.eql(u8, provider, "codex")) {
        const c = readCodexCred(arena) catch |e| return errJson(arena, e);
        try buf.append(arena, '{');
        try buf.appendSlice(arena, "\"access_token\":");
        try jsonString(&buf, arena, c.access_token);
        if (c.account_id) |aid| {
            try buf.appendSlice(arena, ",\"account_id\":");
            try jsonString(&buf, arena, aid);
        }
        try buf.append(arena, '}');
    } else {
        return errJson(arena, error.UnknownProvider);
    }
    return buf.toOwnedSlice(arena);
}

fn errJson(arena: std.mem.Allocator, e: anyerror) ![]u8 {
    var buf: Buf = .empty;
    try buf.appendSlice(arena, "{\"access_token\":\"\",\"error\":");
    try jsonString(&buf, arena, @errorName(e));
    try buf.append(arena, '}');
    return buf.toOwnedSlice(arena);
}

// ── MCP dispatch ──────────────────────────────────────────────────────

fn handleMessage(arena: std.mem.Allocator, msg: []const u8) !void {
    const method = extractStringField(msg, "method") orelse return;
    const id = extractIdRaw(msg);

    if (std.mem.eql(u8, method, "initialize")) {
        var resp: Buf = .empty;
        defer resp.deinit(arena);
        try resp.print(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{\"listChanged\":false}}}},\"serverInfo\":{{\"name\":\"aicreds\",\"version\":\"0.1.0\"}}}}}}", .{id});
        try writeFramed(resp.items);
        return;
    }
    if (std.mem.eql(u8, method, "notifications/initialized")) return;

    if (std.mem.eql(u8, method, "tools/call")) {
        const tool = extractStringField(msg, "name") orelse {
            try writeError(arena, id, -32602, "missing tool name");
            return;
        };
        if (!std.mem.eql(u8, tool, "aicreds.read")) {
            try writeError(arena, id, -32601, "unknown tool");
            return;
        }
        const provider = extractStringField(msg, "provider") orelse "";
        const inner = buildRead(arena, provider) catch |e| {
            try writeError(arena, id, -32603, @errorName(e));
            return;
        };
        var resp: Buf = .empty;
        defer resp.deinit(arena);
        try resp.print(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":", .{id});
        try jsonString(&resp, arena, inner);
        try resp.appendSlice(arena, "}],\"isError\":false}}");
        try writeFramed(resp.items);
        return;
    }
    try writeError(arena, id, -32601, "method not found");
}

fn runMcpLoop() !void {
    const backing = std.heap.smp_allocator;
    while (true) {
        var arena_state = std.heap.ArenaAllocator.init(backing);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const body = readFramed(arena) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        handleMessage(arena, body) catch |err| {
            var msg_buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&msg_buf, "aicreds handle error: {s}\n", .{@errorName(err)}) catch continue;
            _ = write(stderr_fd, m.ptr, m.len);
        };
    }
}

/// Token-free health check for local verification (`aicreds --check`):
/// prints whether each provider's credential is readable and the token
/// length — never the token itself.
fn runCheck() !void {
    const backing = std.heap.smp_allocator;
    var arena_state = std.heap.ArenaAllocator.init(backing);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (readClaudeToken(arena)) |t| {
        var b: [64]u8 = undefined;
        const l = std.fmt.bufPrint(&b, "claude: ok (len={d})\n", .{t.len}) catch return;
        _ = write(stdout_fd, l.ptr, l.len);
    } else |e| {
        var b: [64]u8 = undefined;
        const l = std.fmt.bufPrint(&b, "claude: ERR {s}\n", .{@errorName(e)}) catch return;
        _ = write(stdout_fd, l.ptr, l.len);
    }
    if (readCodexCred(arena)) |c| {
        var b: [80]u8 = undefined;
        const l = std.fmt.bufPrint(&b, "codex:  ok (len={d}, account_id={s})\n", .{ c.access_token.len, if (c.account_id != null) "yes" else "no" }) catch return;
        _ = write(stdout_fd, l.ptr, l.len);
    } else |e| {
        var b: [64]u8 = undefined;
        const l = std.fmt.bufPrint(&b, "codex:  ERR {s}\n", .{@errorName(e)}) catch return;
        _ = write(stdout_fd, l.ptr, l.len);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var it = init.args.iterate();
    _ = it.next(); // argv[0]
    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--check")) return runCheck();
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help =
                "aicreds — read local AI tool OAuth tokens\n" ++
                "Usage:\n" ++
                "  aicreds            # MCP stdio plugin mode (default)\n" ++
                "  aicreds --check    # token-free readability check\n";
            _ = write(stdout_fd, help.ptr, help.len);
            return;
        }
    }
    tlog("=== aicreds start pid={d} ===", .{std.c.getpid()});
    return runMcpLoop();
}
