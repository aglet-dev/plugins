//! tokstat — AI coding token-usage probe over MCP stdio.
//!
//! v0.1 probes Claude only. Strategy: spawn `claude --allowed-tools ""`
//! inside a PTY, wait for the welcome screen, send `/usage`, drain the
//! rendered Usage panel for a few seconds, ESC+Ctrl-C to exit, strip
//! ANSI, then scan the resulting blob for the Current-session and
//! Current-week (all models) panels. The host CLI's `/usage` only
//! renders in a TTY (`-p` mode prints a plain "you have a subscription"
//! line and bypasses the panel renderer), so PTY is required.
//!
//! Dual-mode:
//!   tokstat              — MCP JSON-RPC over stdio (LSP Content-Length
//!                          framing). Periodic emitter pushes a
//!                          `notifications/resources/updated` frame
//!                          every TOKSTAT_INTERVAL_SECS (default 60s,
//!                          floor 30s — each probe spawns the whole
//!                          claude CLI so faster is wasteful).
//!   tokstat --jsonl      — dump one JSON line per probe tick to stdout
//!                          and exit on SIGINT. Use --interval=<secs>
//!                          to override the cadence.
//!
//! macOS-first. `forkpty` is in libSystem on Darwin (zero-link); Linux
//! support needs `-lutil` which the build.zig doesn't link yet — left
//! as a follow-up.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// ── libc bindings ──────────────────────────────────────────────────────

const stdin_fd: posix.fd_t = 0;
const stdout_fd: posix.fd_t = 1;
const stderr_fd: posix.fd_t = 2;

extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn forkpty(amaster: *c_int, name: ?[*]u8, termp: ?*anyopaque, winp: ?*Winsize) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
const fcntl = std.c.fcntl;
extern "c" fn time(t: ?*c_long) c_long;
const Timeval = extern struct { tv_sec: c_long, tv_usec: c_int };
extern "c" fn gettimeofday(tv: *Timeval, tz: ?*anyopaque) c_int;
fn nowMs() i64 {
    var tv: Timeval = .{ .tv_sec = 0, .tv_usec = 0 };
    _ = gettimeofday(&tv, null);
    return @as(i64, tv.tv_sec) * 1000 + @divTrunc(@as(i64, tv.tv_usec), 1000);
}
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// Time conversion (Darwin / BSD tm shape — Linux struct is wider with
// tm_gmtoff + tm_zone too; we read fields by name so layout drift is OK
// as long as the leading nine ints match libc's struct tm).
const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const c_long, tm: *Tm) ?*Tm;
extern "c" fn mktime(tm: *Tm) c_long;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn lseek(fd: c_int, off: c_long, whence: c_int) c_long;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
const O_RDONLY: c_int = 0;
const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;
const F_OK: c_int = 0;

const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0x0004; // darwin
const WNOHANG: c_int = 1;
const SIGINT: c_int = 2;
const SIGKILL: c_int = 9;

const Winsize = extern struct {
    ws_row: c_ushort,
    ws_col: c_ushort,
    ws_xpixel: c_ushort,
    ws_ypixel: c_ushort,
};

// ── pthread for stdout mutex + emitter thread (same shape as sysmon) ─

const pthread_t = std.c.pthread_t;
const pthread_mutex_t = std.c.pthread_mutex_t;
extern "c" fn pthread_create(thread: *pthread_t, attr: ?*anyopaque, start_routine: *const fn (?*anyopaque) callconv(.c) ?*anyopaque, arg: ?*anyopaque) c_int;
extern "c" fn pthread_detach(thread: pthread_t) c_int;
extern "c" fn pthread_mutex_lock(m: *pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_unlock(m: *pthread_mutex_t) c_int;

var stdout_mu: pthread_mutex_t = .{};
var cache_mu: pthread_mutex_t = .{};
var emitter_started: bool = false;

// Plugin debug log。写 stderr —— daemon 端 stdio_plugin 有 reader thread
// 实时 drain 转发到 aglet runtime log（前缀 "[plugin:tokstat] "）。`--jsonl`
// CLI 模式同样能看（直接进终端 stderr）。
fn tlog(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = write(stderr_fd, out.ptr, out.len);
}

// Cached last probe result, JSON-encoded so emit + tools/call share one
// path. `null` until the first probe finishes.
var cached_json: ?[]u8 = null;
var cached_ts: i64 = 0;
const cache_alloc = std.heap.smp_allocator;

// Configurable via env (plugin mode) or CLI flag (--jsonl mode).
var interval_secs: u32 = 60;
const interval_secs_floor: u32 = 30;

fn libcWrite(fd: posix.fd_t, buf: []const u8) !usize {
    const n = write(fd, buf.ptr, buf.len);
    if (n < 0) return error.WriteFailed;
    return @intCast(n);
}

fn ptyWrite(fd: c_int, buf: []const u8) void {
    _ = write(fd, buf.ptr, buf.len);
}

fn ptyRead(fd: c_int, buf: []u8) isize {
    return read(fd, buf.ptr, buf.len);
}

// ── LSP-style framing (identical to sysmon) ───────────────────────────

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
        const n = try libcWrite(stdout_fd, buf[sent..]);
        if (n == 0) return error.WriteFailed;
        sent += n;
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
    _ = pthread_mutex_lock(&stdout_mu);
    defer _ = pthread_mutex_unlock(&stdout_mu);
    try writeAllStdout(h);
    try writeAllStdout(body);
}

// ── PTY probe of `claude /usage` ──────────────────────────────────────

const Probe = struct {
    ok: bool,
    err: ?[]const u8,
    session_pct: ?u32,
    session_resets: ?[]const u8,
    session_resets_ms: ?i64,
    weekly_pct: ?u32,
    weekly_resets: ?[]const u8,
    weekly_resets_ms: ?i64,
    total_cost_usd: ?f64,
    raw_panel: ?[]const u8, // best-effort excerpt for debugging
};

fn probeClaude(arena: std.mem.Allocator) Probe {
    tlog("claude: probe start (try HTTP first)", .{});
    // HTTP 优先:Claude Code 的 OAuth token(Keychain)直调 api.anthropic.com/api/oauth/usage
    // —— 永远新、不依赖 PTY 抓屏(脆),拿干净 JSON(five_hour/seven_day utilization + ISO resets_at)。
    // 与 codex 的 HTTP-优先/JSONL-兜底对称。失败(无 token / 401 过期 / 网断)→ PTY 抓屏兜底。
    if (probeClaudeHttp(arena)) |p| {
        tlog("claude: http ok session={?d}% weekly={?d}%", .{ p.session_pct, p.weekly_pct });
        return p;
    } else |e| {
        tlog("claude: http ERR={s}, fallback PTY", .{@errorName(e)});
    }
    const p = probeClaudeInner(arena) catch |e| {
        tlog("claude: pty ERR={s}", .{@errorName(e)});
        return .{
            .ok = false,
            .err = @errorName(e),
            .session_pct = null,
            .session_resets = null,
            .session_resets_ms = null,
            .weekly_pct = null,
            .weekly_resets = null,
            .weekly_resets_ms = null,
            .total_cost_usd = null,
            .raw_panel = null,
        };
    };
    tlog("claude: pty ok session={?d}% weekly={?d}%", .{ p.session_pct, p.weekly_pct });
    return p;
}

/// HTTP 路径:从 macOS Keychain 取 Claude Code 的 OAuth access token,
/// curl `https://api.anthropic.com/api/oauth/usage`(Bearer)。任意失败 → 抛错让
/// caller 回退 PTY。注:首次从非-Claude-Code 进程读该 Keychain 项可能弹一次授权
/// (之后可「始终允许」);codex 的 ~/.codex/auth.json 是明文无此问题。
fn probeClaudeHttp(arena: std.mem.Allocator) !Probe {
    // 1) Keychain → {"claudeAiOauth":{"accessToken":...}}
    const kc = try spawnCaptureStdout(arena, &.{
        "/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w",
    });
    var kparsed = std.json.parseFromSlice(std.json.Value, arena, std.mem.trim(u8, kc, " \t\r\n"), .{}) catch return error.KcParse;
    defer kparsed.deinit();
    const kroot = switch (kparsed.value) { .object => |o| o, else => return error.KcShape };
    const oauth = switch (kroot.get("claudeAiOauth") orelse return error.KcNoOauth) {
        .object => |o| o, else => return error.KcShape,
    };
    const access_tok = switch (oauth.get("accessToken") orelse return error.KcNoToken) {
        .string => |s| s, else => return error.KcShape,
    };

    // 2) curl /api/oauth/usage
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(arena);
    try args.append(arena, "/usr/bin/curl");
    try args.append(arena, "-sS");
    try args.append(arena, "--max-time");
    try args.append(arena, "8");
    try args.append(arena, "-H");
    try args.append(arena, try std.fmt.allocPrint(arena, "Authorization: Bearer {s}", .{access_tok}));
    try args.append(arena, "-H");
    try args.append(arena, "Accept: application/json");
    try args.append(arena, "-H");
    try args.append(arena, "User-Agent: tokstat");
    try args.append(arena, "https://api.anthropic.com/api/oauth/usage");
    const body = try spawnCaptureStdout(arena, args.items);

    // 3) parse {five_hour:{utilization,resets_at}, seven_day:{...}}
    var uparsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return error.UsageParse;
    defer uparsed.deinit();
    const uroot = switch (uparsed.value) { .object => |o| o, else => return error.UsageShape };

    var p: Probe = .{
        .ok = false, .err = null,
        .session_pct = null, .session_resets = null, .session_resets_ms = null,
        .weekly_pct = null, .weekly_resets = null, .weekly_resets_ms = null,
        .total_cost_usd = null, .raw_panel = null,
    };
    fillWindow(arena, uroot, "five_hour", &p.session_pct, &p.session_resets, &p.session_resets_ms);
    fillWindow(arena, uroot, "seven_day", &p.weekly_pct, &p.weekly_resets, &p.weekly_resets_ms);
    p.ok = p.session_pct != null or p.weekly_pct != null;
    if (!p.ok) return error.UsageEmpty; // 让 caller 回退 PTY
    return p;
}

/// 从 usage JSON 的某个 window(five_hour / seven_day)抽 utilization(%) + resets_at(ISO)。
fn fillWindow(arena: std.mem.Allocator, root: std.json.ObjectMap, key: []const u8, pct: *?u32, resets: *?[]const u8, resets_ms: *?i64) void {
    const w = switch (root.get(key) orelse return) { .object => |o| o, else => return };
    if (w.get("utilization")) |uv| {
        const f: ?f64 = switch (uv) { .float => |x| x, .integer => |i| @floatFromInt(i), else => null };
        if (f) |x| pct.* = @intFromFloat(@round(x));
    }
    if (w.get("resets_at")) |rv| if (rv == .string) {
        resets.* = arena.dupe(u8, rv.string) catch null;
        resets_ms.* = parseIsoUtcMs(rv.string);
    };
}

/// ISO-8601 UTC("2026-06-29T10:30:00.257936+00:00")→ epoch ms。resets_at 恒为 +00:00。
/// 用 Hinnant days_from_civil 算,不依赖 libc mktime(那个是本地时区)。
fn parseIsoUtcMs(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[10] != 'T') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const se = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    const yy = y - @as(i64, if (mo <= 2) 1 else 0);
    const era = @divFloor(if (yy >= 0) yy else yy - 399, 400);
    const yoe = yy - era * 400;
    const doy = @divFloor(153 * (mo + @as(i64, if (mo > 2) -3 else 9)) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return (days * 86400 + h * 3600 + mi * 60 + se) * 1000;
}

fn findTrustedDir(arena: std.mem.Allocator) ?[:0]const u8 {
    const home_cstr = getenv("HOME") orelse return null;
    const home = std.mem.span(home_cstr);
    const path = std.fmt.allocPrintSentinel(arena, "{s}/.claude.json", .{home}, 0) catch return null;
    const fd = open(path.ptr, O_RDONLY);
    if (fd < 0) return null;
    defer _ = close(fd);
    const sz = lseek(fd, 0, SEEK_END);
    if (sz <= 0 or sz > 64 * 1024 * 1024) return null;
    _ = lseek(fd, 0, SEEK_SET);
    const data = arena.alloc(u8, @intCast(sz)) catch return null;
    var got: usize = 0;
    while (got < data.len) {
        const r = read(fd, data.ptr + got, data.len - got);
        if (r <= 0) break;
        got += @intCast(r);
    }
    if (got == 0) return null;

    // Walk the projects map forward: `"projects": { "<absPath>": { ... }, ... }`.
    // We don't need a full JSON parser — match the top-level keys that
    // start with a slash (absolute path) and look ahead within their
    // object for `"hasTrustDialogAccepted": true`.
    const projects_anchor = std.mem.indexOf(u8, data[0..got], "\"projects\"") orelse return null;
    const obj_start = std.mem.indexOfScalarPos(u8, data[0..got], projects_anchor, '{') orelse return null;
    var i: usize = obj_start + 1;
    var depth: i32 = 1;
    while (i < got and depth > 0) {
        const c = data[i];
        if (c == '"' and depth == 1) {
            // Top-level key in projects map. Scan to closing quote.
            const ks = i + 1;
            var ke = ks;
            while (ke < got and data[ke] != '"') : (ke += 1) {
                if (data[ke] == '\\') ke += 1;
            }
            if (ke >= got) return null;
            const key = data[ks..ke];
            i = ke + 1;
            // Find this entry's object body.
            const obj_open = std.mem.indexOfScalarPos(u8, data[0..got], i, '{') orelse return null;
            // Match braces to find object close.
            var j: usize = obj_open + 1;
            var d2: i32 = 1;
            while (j < got and d2 > 0) : (j += 1) {
                const cc = data[j];
                if (cc == '"') {
                    j += 1;
                    while (j < got and data[j] != '"') : (j += 1) {
                        if (data[j] == '\\') j += 1;
                    }
                } else if (cc == '{') {
                    d2 += 1;
                } else if (cc == '}') {
                    d2 -= 1;
                }
            }
            const obj_end = j;
            const body = data[obj_open..obj_end];
            if (key.len > 0 and key[0] == '/' and
                std.mem.indexOf(u8, body, "\"hasTrustDialogAccepted\": true") != null)
            {
                const z = arena.dupeZ(u8, key) catch return null;
                if (access(z.ptr, F_OK) == 0) return z;
            }
            i = obj_end;
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') depth -= 1;
        i += 1;
    }
    return null;
}

fn probeClaudeInner(arena: std.mem.Allocator) !Probe {
    // Pick a trusted folder so we never deadlock on the safety dialog.
    const trusted = findTrustedDir(arena);

    var master_fd: c_int = -1;
    var ws: Winsize = .{ .ws_row = 40, .ws_col = 110, .ws_xpixel = 0, .ws_ypixel = 0 };
    const pid = forkpty(&master_fd, null, null, &ws);
    if (pid < 0) return error.ForkptyFailed;

    if (pid == 0) {
        if (trusted) |dir| {
            _ = chdir(dir.ptr);
        } else if (getenv("HOME")) |home| _ = chdir(home);
        // Force a known TERM so claude's TUI uses xterm-compatible
        // sequences and doesn't lock waiting on exotic queries.
        _ = setenv("TERM", "xterm-256color", 1);
        var argv = [_:null]?[*:0]const u8{ "claude", "--allowed-tools", "" };
        _ = execvp("claude", &argv);
        _exit(127);
    }

    defer {
        // Best-effort teardown. SIGKILL the child, reap with bounded
        // WNOHANG polling (waitpid(...,0) would block forever if SIGKILL
        // somehow didn't land), then close master.
        _ = kill(pid, SIGKILL);
        var status: c_int = 0;
        var tries: u32 = 0;
        while (tries < 50) : (tries += 1) {
            const r = waitpid(pid, &status, WNOHANG);
            if (r == pid or r < 0) break;
            _ = usleep(20_000);
        }
        _ = close(master_fd);
    }

    // Non-blocking master so the read loop can poll with sleeps.
    const flags = fcntl(master_fd, F_GETFL, @as(c_int, 0));
    _ = fcntl(master_fd, F_SETFL, @as(c_int, flags | O_NONBLOCK));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);

    const deadline_ms: i64 = nowMs() + 30_000;
    var usage_sent = false;
    var trust_acked = false;
    var quiet_after_usage_ms: i64 = 0;
    var first_byte_ms: ?i64 = null;
    var panel_first_seen_ms: ?i64 = null;

    while (nowMs() < deadline_ms) {
        var chunk: [4096]u8 = undefined;
        const rc = ptyRead(master_fd, &chunk);
        const n: usize = if (rc > 0) @intCast(rc) else 0;
        if (rc < 0) {
            // Likely EAGAIN under O_NONBLOCK; treat as quiet tick.
            _ = usleep(50_000);
            if (usage_sent) quiet_after_usage_ms += 50;
            if (usage_sent and quiet_after_usage_ms > 1500) break;
            continue;
        }
        if (n == 0) {
            _ = usleep(50_000);
            if (usage_sent) quiet_after_usage_ms += 50;
            if (usage_sent and quiet_after_usage_ms > 1500) break;
            continue;
        }
        try buf.appendSlice(arena, chunk[0..n]);
        if (first_byte_ms == null) first_byte_ms = nowMs();
        if (usage_sent) quiet_after_usage_ms = 0;

        // Auto-respond to Primary DA query (claude emits ESC[c on startup
        // and on dialog transitions, waiting for the terminal's reply
        // before reading further keystrokes — a real xterm answers
        // `ESC[?1;2c`, the kernel PTY does not, so we forge it here).
        if (std.mem.indexOf(u8, buf.items, "\x1b[c") != null) {
            ptyWrite(master_fd, "\x1b[?1;2c");
        }
        if (!trust_acked) {
            if (std.mem.indexOf(u8, buf.items, "trust this folder") != null or
                std.mem.indexOf(u8, buf.items, "Quick safety check") != null)
            {
                _ = usleep(150_000);
                ptyWrite(master_fd, "\r");
                trust_acked = true;
                first_byte_ms = nowMs();
            }
        }
        if (!usage_sent) {
            const seen_banner = std.mem.indexOf(u8, buf.items, "Welcome back") != null or
                std.mem.indexOf(u8, buf.items, "Welcome to Claude") != null or
                std.mem.indexOf(u8, buf.items, "Try \"") != null;
            const since_first = nowMs() - (first_byte_ms orelse nowMs());
            if (seen_banner and since_first > 600) {
                ptyWrite(master_fd, "/usage\r");
                usage_sent = true;
            } else if (since_first > 12000 and buf.items.len > 0) {
                ptyWrite(master_fd, "/usage\r");
                usage_sent = true;
            }
        }
        // Stop early once the panel's **percent value** has rendered and settled.
        // 关键:gate 在 "%used"(真正要解析的数字)出现,而不是 "Current session"
        // 标签 —— claude 慢渲染/限流时标签先出、百分比晚出,只等标签会截到没数字的
        // 半成品 → panel-not-recognized。等数字出现再 settle，确保 session+week 都渲染好。
        if (usage_sent) {
            if (panel_first_seen_ms == null and
                std.mem.indexOf(u8, buf.items, "%used") != null)
            {
                panel_first_seen_ms = nowMs();
            }
            if (panel_first_seen_ms) |t| if (nowMs() - t > 1000) break;
        }
    }

    // Try to exit cleanly so the subprocess doesn't linger in the
    // background filling its tty buffer.
    ptyWrite(master_fd, "\x1b"); // close popover
    _ = usleep(80_000);
    ptyWrite(master_fd, "\x03"); // Ctrl-C
    _ = usleep(80_000);
    ptyWrite(master_fd, "\x03");

    if (!usage_sent) return error.UsagePromptNeverReady;
    if (buf.items.len == 0) return error.NoOutput;

    const stripped = try stripAnsi(arena, buf.items);
    if (getenv("TOKSTAT_DEBUG_DUMP")) |_| {
        _ = libcWrite(stderr_fd, "--- STRIPPED START ---\n") catch {};
        _ = libcWrite(stderr_fd, stripped) catch {};
        _ = libcWrite(stderr_fd, "\n--- STRIPPED END ---\n") catch {};
    }
    return parsePanel(arena, stripped);
}

// ── ANSI / control-sequence stripping ─────────────────────────────────

fn stripAnsi(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == 0x1b) {
            if (i + 1 >= raw.len) {
                i += 1;
                continue;
            }
            const nxt = raw[i + 1];
            switch (nxt) {
                '[' => {
                    // CSI: ESC [ <param>* <intermediate>* <final 0x40-0x7e>
                    i += 2;
                    while (i < raw.len) : (i += 1) {
                        const cc = raw[i];
                        if (cc >= 0x40 and cc <= 0x7e) {
                            i += 1;
                            break;
                        }
                    }
                },
                ']' => {
                    // OSC: terminated by BEL or ST
                    i += 2;
                    while (i < raw.len) : (i += 1) {
                        if (raw[i] == 0x07) {
                            i += 1;
                            break;
                        }
                        if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '\\') {
                            i += 2;
                            break;
                        }
                    }
                },
                'P', '^', '_' => {
                    // DCS / PM / APC — terminated by ST
                    i += 2;
                    while (i < raw.len) : (i += 1) {
                        if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '\\') {
                            i += 2;
                            break;
                        }
                    }
                },
                '(', ')', '*', '+' => {
                    // Charset designation, 1 byte follows
                    i += 3;
                },
                else => {
                    // 2-byte escape (NEL, IND, etc.)
                    i += 2;
                },
            }
            continue;
        }
        // Drop CR; keep LF. Many TUIs emit lone CR for cursor reset.
        if (c == '\r') {
            i += 1;
            continue;
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

// ── Panel parsing ─────────────────────────────────────────────────────
//
// After ANSI strip the buffer is a mostly-spaceful blob with occasional
// LFs (claude positions text with cursor moves, not \n). Useful tokens:
//
//   "Current session"            ... "<N>% used" ... "Resets <human> (TZ)"
//   "Current week (all models)"  ... "<N>% used" ... "Resets <human> (TZ)"
//   "Total cost:" then "$<float>"
//
// We slice between landmarks to keep "Current session"'s scan from
// straying into the week panel.

fn parsePanel(arena: std.mem.Allocator, stripped: []u8) !Probe {
    var p: Probe = .{
        .ok = false,
        .err = null,
        .session_pct = null,
        .session_resets = null,
        .session_resets_ms = null,
        .weekly_pct = null,
        .weekly_resets = null,
        .weekly_resets_ms = null,
        .total_cost_usd = null,
        .raw_panel = null,
    };

    // Anchor the search after the menu header so an earlier word
    // "Session" in some banner doesn't trip us. Tolerate missing anchor.
    var search_blob = stripped;
    if (std.mem.indexOf(u8, stripped, "Usage")) |u_idx| {
        search_blob = stripped[u_idx..];
    }

    // 用 lastIndexOf 锚**最后一帧**:PTY buf 累积了多次重绘,早期帧可能标签已出但
    // 百分比未渲染(切片到那帧 → 抽不到 %)。最后一帧最完整。
    if (std.mem.lastIndexOf(u8, search_blob, "Current session")) |s_idx| {
        const session_end = std.mem.indexOfPos(u8, search_blob, s_idx, "Current week") orelse search_blob.len;
        const slice = search_blob[s_idx..session_end];
        const v = extractPanelValues(slice);
        p.session_pct = v.pct;
        if (v.resets) |r| {
            p.session_resets = try arena.dupe(u8, r);
            p.session_resets_ms = parseResetEpochMs(r);
        }
    }

    // Prefer the "(all models)" panel; fall back to bare "Current week"。同样取最后一帧。
    var weekly_slice_opt: ?[]const u8 = null;
    if (std.mem.lastIndexOf(u8, search_blob, "Current week (all models)")) |w_idx| {
        var end = search_blob.len;
        if (std.mem.indexOfPos(u8, search_blob, w_idx + 25, "Current week (")) |w2| end = w2;
        weekly_slice_opt = search_blob[w_idx..end];
    } else if (std.mem.lastIndexOf(u8, search_blob, "Current week")) |w_idx| {
        weekly_slice_opt = search_blob[w_idx..];
    }
    if (weekly_slice_opt) |slice| {
        const v = extractPanelValues(slice);
        p.weekly_pct = v.pct;
        if (v.resets) |r| {
            p.weekly_resets = try arena.dupe(u8, r);
            p.weekly_resets_ms = parseResetEpochMs(r);
        }
    }

    // Total cost — scan for "Total cost:" then a "$" then a float.
    if (std.mem.indexOf(u8, stripped, "Total cost:")) |c_idx| {
        const tail = stripped[c_idx..@min(c_idx + 200, stripped.len)];
        if (std.mem.indexOfScalar(u8, tail, '$')) |d_idx| {
            const num_start = d_idx + 1;
            var num_end = num_start;
            while (num_end < tail.len) : (num_end += 1) {
                const ch = tail[num_end];
                if (!((ch >= '0' and ch <= '9') or ch == '.')) break;
            }
            if (num_end > num_start) {
                p.total_cost_usd = std.fmt.parseFloat(f64, tail[num_start..num_end]) catch null;
            }
        }
    }

    p.ok = p.session_pct != null or p.weekly_pct != null;
    if (!p.ok) p.err = "panel-not-recognized";
    return p;
}

// Convert claude's human reset string (`5:40pm (Asia/Tokyo)` or
// `Jun 1 at 1pm (Asia/Tokyo)`) to absolute epoch ms. The TZ in parens is
// claude's display TZ which on a normal install matches the system TZ —
// we just resolve via libc mktime (local time). If only a time is given
// and that time already passed today, bump to tomorrow.
fn parseResetEpochMs(raw: []const u8) ?i64 {
    var s = raw;
    if (std.mem.indexOfScalar(u8, s, '(')) |op| {
        var e = op;
        while (e > 0 and s[e - 1] == ' ') : (e -= 1) {}
        s = s[0..e];
    }
    s = std.mem.trim(u8, s, " \t");
    if (s.len == 0) return null;

    var now_tt: c_long = 0;
    _ = time(&now_tt);
    var tm: Tm = std.mem.zeroes(Tm);
    if (localtime_r(&now_tt, &tm) == null) return null;

    var has_date = false;
    var i: usize = 0;
    const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    if (s.len >= 3) {
        var lower3: [3]u8 = undefined;
        for (0..3) |k| lower3[k] = std.ascii.toLower(s[k]);
        for (months, 0..) |m, idx| {
            if (std.mem.eql(u8, &lower3, m)) {
                tm.tm_mon = @intCast(idx);
                has_date = true;
                i = 3;
                while (i < s.len and std.ascii.isAlphabetic(s[i])) : (i += 1) {}
                while (i < s.len and s[i] == ' ') : (i += 1) {}
                var d_end = i;
                while (d_end < s.len and std.ascii.isDigit(s[d_end])) : (d_end += 1) {}
                if (d_end > i) {
                    tm.tm_mday = std.fmt.parseInt(c_int, s[i..d_end], 10) catch tm.tm_mday;
                    i = d_end;
                }
                break;
            }
        }
    }
    while (i < s.len and s[i] == ' ') : (i += 1) {}
    if (i + 3 <= s.len and std.ascii.eqlIgnoreCase(s[i .. i + 3], "at ")) i += 3;
    while (i < s.len and s[i] == ' ') : (i += 1) {}

    var h: c_int = 0;
    var m: c_int = 0;
    var h_end = i;
    while (h_end < s.len and std.ascii.isDigit(s[h_end])) : (h_end += 1) {}
    if (h_end == i) return null;
    h = std.fmt.parseInt(c_int, s[i..h_end], 10) catch return null;
    i = h_end;
    if (i < s.len and s[i] == ':') {
        i += 1;
        var m_end = i;
        while (m_end < s.len and std.ascii.isDigit(s[m_end])) : (m_end += 1) {}
        m = std.fmt.parseInt(c_int, s[i..m_end], 10) catch 0;
        i = m_end;
    }
    while (i < s.len and s[i] == ' ') : (i += 1) {}
    if (i + 1 < s.len) {
        const a = std.ascii.toLower(s[i]);
        const b = std.ascii.toLower(s[i + 1]);
        if (a == 'p' and b == 'm' and h < 12) h += 12;
        if (a == 'a' and b == 'm' and h == 12) h = 0;
    }

    tm.tm_hour = h;
    tm.tm_min = m;
    tm.tm_sec = 0;
    tm.tm_isdst = -1; // let mktime resolve DST

    var tt = mktime(&tm);
    if (tt < 0) return null;

    if (!has_date) {
        // Time-only: claude shows the next reset (≤5h away). If our
        // computed point already passed, push to tomorrow.
        if (tt <= now_tt) {
            tm.tm_mday += 1;
            tm.tm_isdst = -1;
            tt = mktime(&tm);
        }
    } else if (tt + 86400 < now_tt) {
        // Date present but before today (Dec→Jan rollover): bump year.
        tm.tm_year += 1;
        tm.tm_isdst = -1;
        tt = mktime(&tm);
    }
    if (tt < 0) return null;
    return @as(i64, tt) * 1000;
}

const PanelValues = struct { pct: ?u32, resets: ?[]const u8 };

fn extractPanelValues(slice: []const u8) PanelValues {
    var out: PanelValues = .{ .pct = null, .resets = null };

    if (std.mem.indexOf(u8, slice, "%used")) |p_idx| {
        // Walk backwards over digits (skipping leading spaces).
        var digits: [4]u8 = undefined;
        var dn: usize = 0;
        var j: isize = @as(isize, @intCast(p_idx)) - 1;
        // Skip optional spaces right before '%'.
        while (j >= 0 and slice[@intCast(j)] == ' ') : (j -= 1) {}
        while (j >= 0 and dn < digits.len) : (j -= 1) {
            const ch = slice[@intCast(j)];
            if (ch >= '0' and ch <= '9') {
                digits[dn] = ch;
                dn += 1;
            } else break;
        }
        if (dn > 0) {
            var rev: [4]u8 = undefined;
            for (0..dn) |k| rev[k] = digits[dn - 1 - k];
            out.pct = std.fmt.parseInt(u32, rev[0..dn], 10) catch null;
        }
    }

    if (std.mem.indexOf(u8, slice, "Resets ")) |r_idx| {
        const rstart = r_idx + "Resets ".len;
        var rend = @min(rstart + 80, slice.len);
        // Stop at next major landmark.
        const stops = [_][]const u8{ "Current ", "What's", "\n\n", "Approximate" };
        for (stops) |stop| {
            if (std.mem.indexOfPos(u8, slice, rstart, stop)) |sp| {
                if (sp < rend) rend = sp;
            }
        }
        // Prefer to keep the closing ')' if a paren block is in range.
        if (std.mem.indexOfScalarPos(u8, slice, rstart, '(')) |op| {
            if (op < rend) {
                if (std.mem.indexOfScalarPos(u8, slice, op, ')')) |cp| {
                    if (cp + 1 <= rend) rend = cp + 1;
                }
            }
        }
        const trimmed = std.mem.trim(u8, slice[rstart..rend], " \t\n");
        if (trimmed.len > 0) out.resets = trimmed;
    }

    return out;
}

// ── Codex rollout probe ───────────────────────────────────────────────
//
// Codex CLI 不像 claude 那样有 `/usage` 面板可以拉。它把每轮对话的
// rate-limit snapshot 落到 session rollout JSONL：
//   ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
// 每行是一个事件，含 rate-limit 那种长这样：
//   {"timestamp":"...","type":"event_msg",
//    "payload":{"type":"token_count",
//               "info":{...},
//               "rate_limits":{"primary":{"used_percent":1.0,
//                                          "window_minutes":300,
//                                          "resets_at":<unix_secs>},
//                              "secondary":{"used_percent":16.0,
//                                            "window_minutes":10080,
//                                            "resets_at":<unix_secs>},
//                              "plan_type":"team",...}}}
// 策略：找 mtime 最新的 rollout，从末尾向前扫第一条 `"type":"token_count"`
// 且 rate_limits 非 null 的行。整 file 一般 < 几 MB，read tail 16KB 够覆
// 盖一两个 token_count 事件。
//
// vs claude PTY 路径：codex 这条没子进程开销，纯 fs read，可以高频。

const CodexProbe = struct {
    ok: bool,
    err: ?[]const u8,
    /// "http" (chatgpt.com/backend-api/wham/usage) or "jsonl" (~/.codex/sessions rollout).
    /// "" when ok=false.
    source: []const u8,
    session_pct: ?u32, // primary (5h window)
    session_resets_ms: ?i64,
    weekly_pct: ?u32, // secondary (7d window)
    weekly_resets_ms: ?i64,
    plan_type: ?[]const u8,
    /// HTTP-only：has_credits / unlimited / balance（balance 是 number 或 null
    /// → 这里 stringify 给 UI 直接显示 "—" / "1.2345"）。JSONL 路径都 null。
    credits_has: ?bool = null,
    credits_unlimited: ?bool = null,
    credits_balance: ?[]const u8 = null,
};

/// Codex usage 探针。优先 HTTP（`chatgpt.com/backend-api/wham/usage`，OAuth
/// access_token 从 `~/.codex/auth.json`）—— 永远新、不依赖最近有过 codex 调用。
/// HTTP 失败（401 token 过期 / 网断 / curl 不在）退化到 JSONL rollout 扫描。
fn probeCodex(arena: std.mem.Allocator) CodexProbe {
    tlog("codex: probe start (try HTTP first)", .{});
    if (probeCodexHttp(arena)) |p| {
        tlog("codex: http ok session={?d}% weekly={?d}% plan={s}", .{ p.session_pct, p.weekly_pct, p.plan_type orelse "-" });
        return p;
    } else |e| {
        tlog("codex: http ERR={s}, fallback JSONL", .{@errorName(e)});
    }
    const p = probeCodexRollout(arena) catch |e| {
        tlog("codex: jsonl ERR={s}", .{@errorName(e)});
        return .{
            .ok = false,
            .err = @errorName(e),
            .source = "",
            .session_pct = null,
            .session_resets_ms = null,
            .weekly_pct = null,
            .weekly_resets_ms = null,
            .plan_type = null,
        };
    };
    tlog("codex: jsonl ok session={?d}% weekly={?d}%", .{ p.session_pct, p.weekly_pct });
    return p;
}

/// HTTP 路径：curl chatgpt.com/backend-api/wham/usage with Bearer token from
/// `~/.codex/auth.json`. 比 JSONL 实时（不需要近期跑过 codex turn）+ 额外
/// 拿 credits / plan_type。token 401 / 网断 / curl 失败 → caller fallback。
fn probeCodexHttp(arena: std.mem.Allocator) !CodexProbe {
    const home_cstr = getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_cstr);
    const auth_path = try std.fmt.allocPrintSentinel(arena, "{s}/.codex/auth.json", .{home}, 0);
    const auth_bytes = try readWholeFile(arena, auth_path);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, auth_bytes, .{}) catch return error.AuthParse;
    defer parsed.deinit();
    const root = switch (parsed.value) { .object => |o| o, else => return error.AuthShape };
    const tokens = switch (root.get("tokens") orelse return error.AuthNoTokens) {
        .object => |o| o, else => return error.AuthShape,
    };
    const access_tok = switch (tokens.get("access_token") orelse return error.AuthNoAccess) {
        .string => |s| s, else => return error.AuthShape,
    };
    const account: ?[]const u8 = blk: {
        const v = tokens.get("account_id") orelse break :blk null;
        break :blk switch (v) { .string => |s| s, else => null };
    };

    // curl 8s 超时；HTTPS 证书走系统 trust store。Bearer + 可选 account header。
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(arena);
    try args.append(arena, "/usr/bin/curl");
    try args.append(arena, "-sS");
    try args.append(arena, "--max-time");
    try args.append(arena, "8");
    try args.append(arena, "-H");
    const auth_header = try std.fmt.allocPrint(arena, "Authorization: Bearer {s}", .{access_tok});
    try args.append(arena, auth_header);
    if (account) |aid| {
        try args.append(arena, "-H");
        try args.append(arena, try std.fmt.allocPrint(arena, "ChatGPT-Account-Id: {s}", .{aid}));
    }
    try args.append(arena, "-H");
    try args.append(arena, "Accept: application/json");
    try args.append(arena, "-H");
    try args.append(arena, "User-Agent: tokstat");
    try args.append(arena, "https://chatgpt.com/backend-api/wham/usage");

    const body = try spawnCaptureStdout(arena, args.items);
    return try parseWhamUsage(arena, body);
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

/// fork + exec + 收 stdout。pipe(2) + posix_spawn 之类的不在 std；自己用
/// pipe + fork + dup2 + execvp + read。失败任意一步 → error。child 不出 30s。
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn fork() c_int;

fn spawnCaptureStdout(arena: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (argv.len == 0) return error.NoArgv;

    // argv → [*:0]const u8 array
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
        // child: redirect stdout to pipe write end, drop stdin/stderr
        _ = dup2(fds[1], stdout_fd);
        _ = close(fds[0]);
        _ = close(fds[1]);
        // stderr → /dev/null（不污染父 stderr 日志）
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
        if (out.items.len > 2 * 1024 * 1024) break; // cap 2MB
    }
    _ = close(fds[0]);

    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);

    return out.toOwnedSlice(arena);
}

fn parseWhamUsage(arena: std.mem.Allocator, body: []const u8) !CodexProbe {
    if (body.len == 0) return error.EmptyResponse;
    // 401 / HTML error page 不是 JSON object 起头 — parse 失败 → caller fallback
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return error.NotJson;
    defer parsed.deinit();
    const root = switch (parsed.value) { .object => |o| o, else => return error.JsonShape };

    var plan_dup: ?[]const u8 = null;
    if (root.get("plan_type")) |v| if (v == .string) {
        plan_dup = arena.dupe(u8, v.string) catch null;
    };

    var session_pct: ?u32 = null;
    var session_resets_ms: ?i64 = null;
    var weekly_pct: ?u32 = null;
    var weekly_resets_ms: ?i64 = null;

    const rl_v = root.get("rate_limit") orelse return error.NoRateLimit;
    if (rl_v != .object) return error.JsonShape;
    if (rl_v.object.get("primary_window")) |pw| if (pw == .object) {
        session_pct = readUsedPct(pw.object);
        session_resets_ms = readResetsMs(pw.object);
    };
    if (rl_v.object.get("secondary_window")) |sw| if (sw == .object) {
        weekly_pct = readUsedPct(sw.object);
        weekly_resets_ms = readResetsMs(sw.object);
    };

    var credits_has: ?bool = null;
    var credits_unlimited: ?bool = null;
    var credits_balance: ?[]const u8 = null;
    if (root.get("credits")) |c| if (c == .object) {
        if (c.object.get("has_credits")) |v| if (v == .bool) {
            credits_has = v.bool;
        };
        if (c.object.get("unlimited")) |v| if (v == .bool) {
            credits_unlimited = v.bool;
        };
        if (c.object.get("balance")) |v| switch (v) {
            .float => |f| credits_balance = std.fmt.allocPrint(arena, "{d:.2}", .{f}) catch null,
            .integer => |i| credits_balance = std.fmt.allocPrint(arena, "{d}", .{i}) catch null,
            .string => |s| credits_balance = arena.dupe(u8, s) catch null,
            else => {},
        };
    };

    if (session_pct == null and weekly_pct == null) return error.NoUsage;

    return CodexProbe{
        .ok = true,
        .err = null,
        .source = "http",
        .session_pct = session_pct,
        .session_resets_ms = session_resets_ms,
        .weekly_pct = weekly_pct,
        .weekly_resets_ms = weekly_resets_ms,
        .plan_type = plan_dup,
        .credits_has = credits_has,
        .credits_unlimited = credits_unlimited,
        .credits_balance = credits_balance,
    };
}

fn probeCodexRollout(arena: std.mem.Allocator) !CodexProbe {
    const home_cstr = getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_cstr);
    const sessions_root = try std.fmt.allocPrint(arena, "{s}/.codex/sessions", .{home});

    const newest = (try findNewestRollout(arena, sessions_root)) orelse return error.NoRollout;
    return try parseLatestTokenCount(arena, newest);
}

// libc DIR / dirent —— readdir 走它，避免 std.Io.Dir 拉 io 实例。
// macOS dirent 头部是 ino(8) + seekoff(8) + reclen(2) + namlen(2) + type(1) + name[]。
// Linux 不同；plugin macOS-first（forkpty 也只在 darwin 链），暂不管 Linux。
const DIR = opaque {};
extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
extern "c" fn readdir(dirp: *DIR) ?*Dirent;
extern "c" fn closedir(dirp: *DIR) c_int;

const Dirent = extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};

// Darwin stat (macOS 10.6+ NEWSTAT layout — _DARWIN_FEATURE_64_BIT_INODE).
const Stat = extern struct {
    dev: c_int,
    mode: u16,
    nlink: u16,
    ino: u64,
    uid: u32,
    gid: u32,
    rdev: c_int,
    atime_sec: c_long,
    atime_nsec: c_long,
    mtime_sec: c_long,
    mtime_nsec: c_long,
    ctime_sec: c_long,
    ctime_nsec: c_long,
    birthtime_sec: c_long,
    birthtime_nsec: c_long,
    size: i64,
    blocks: i64,
    blksize: i32,
    flags: u32,
    gen: u32,
    lspare: i32,
    qspare: [2]i64,
};
// 注意 macOS x86_64 用 `stat$INODE64` 老 ABI 链接符；arm64 / Apple Silicon
// 直接 `stat` —— std.c.stat 已经按 native_arch 路由了。我们的 Stat 布局
// 跟 Darwin BIG_ENDIAN / 64-bit inode 一致；caller 只读 mtime_sec / nsec。
const statC = @extern(*const fn (path: [*:0]const u8, buf: *Stat) callconv(.c) c_int, .{ .name = "stat" });

const Names = std.ArrayList([]const u8);

/// readdir(path) 把 entry 名字 dup 进 arena 后返回；过滤掉 "." / ".."。
/// 不传 DT_REG/DT_DIR 过滤 —— caller 自己看名字 + stat 决定。
fn listDir(arena: std.mem.Allocator, path: []const u8) !Names {
    var out: Names = .empty;
    const path_z = try arena.dupeZ(u8, path);
    const dirp = opendir(path_z.ptr) orelse return out;
    defer _ = closedir(dirp);
    while (readdir(dirp)) |ent| {
        const namlen: usize = ent.d_namlen;
        if (namlen == 0 or namlen > ent.d_name.len) continue;
        const name = ent.d_name[0..namlen];
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const dup = try arena.dupe(u8, name);
        try out.append(arena, dup);
    }
    return out;
}

/// 走 ~/.codex/sessions/ 树（YYYY/MM/DD/rollout-*.jsonl），按 mtime 选最新。
/// 树深度固定 3 (year/month/day/file)；普通三层嵌套循环，没必要 walker。
fn findNewestRollout(arena: std.mem.Allocator, root_path: []const u8) !?[]const u8 {
    var best: ?[]const u8 = null;
    var best_sec: c_long = std.math.minInt(c_long);
    var best_nsec: c_long = 0;

    const years = try listDir(arena, root_path);
    for (years.items) |year| {
        const year_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root_path, year });
        const months = try listDir(arena, year_path);
        for (months.items) |month| {
            const month_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ year_path, month });
            const days = try listDir(arena, month_path);
            for (days.items) |day| {
                const day_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ month_path, day });
                const files = try listDir(arena, day_path);
                for (files.items) |name| {
                    if (!std.mem.startsWith(u8, name, "rollout-")) continue;
                    if (!std.mem.endsWith(u8, name, ".jsonl")) continue;
                    const file_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ day_path, name });
                    const file_path_z = try arena.dupeZ(u8, file_path);
                    var sb: Stat = undefined;
                    if (statC.*(file_path_z.ptr, &sb) != 0) continue;
                    if (sb.mtime_sec > best_sec or
                        (sb.mtime_sec == best_sec and sb.mtime_nsec > best_nsec))
                    {
                        best_sec = sb.mtime_sec;
                        best_nsec = sb.mtime_nsec;
                        best = file_path;
                    }
                }
            }
        }
    }
    return best;
}

/// 读 rollout 文件尾 ~64KB，从末尾向前扫第一条 token_count + rate_limits 非 null。
/// JSON 数值取 primary/secondary used_percent + resets_at + plan_type。
fn parseLatestTokenCount(arena: std.mem.Allocator, path: []const u8) !CodexProbe {
    const path_z = try arena.dupeZ(u8, path);
    const fd = open(path_z.ptr, O_RDONLY);
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    const sz = lseek(fd, 0, SEEK_END);
    if (sz <= 0) return error.EmptyFile;
    const tail_bytes: usize = if (sz < 64 * 1024) @intCast(sz) else 64 * 1024;
    const offset: i64 = sz - @as(i64, @intCast(tail_bytes));
    _ = lseek(fd, offset, SEEK_SET);
    const buf = try arena.alloc(u8, tail_bytes);
    var got: usize = 0;
    while (got < buf.len) {
        const r = read(fd, buf.ptr + got, buf.len - got);
        if (r <= 0) break;
        got += @intCast(r);
    }
    const data = buf[0..got];

    // 从末尾向前扫，每次找上一个换行。tail 切到行中间的第一截不完整：
    //   - offset>0：直接跳掉，rollout 早期内容不在 tail 内
    //   - offset==0：整 tail 是从文件头开始，第一截是合法行 → 也扫
    var line_end: usize = data.len;
    // 去掉末尾的 \n
    while (line_end > 0 and (data[line_end - 1] == '\n' or data[line_end - 1] == '\r'))
        line_end -= 1;
    while (line_end > 0) {
        const nl = std.mem.lastIndexOfScalar(u8, data[0..line_end], '\n');
        const line_start: usize = if (nl) |p| p + 1 else if (offset == 0) 0 else break;
        const line = std.mem.trimEnd(u8, data[line_start..line_end], "\r\n");
        if (line.len > 0) {
            if (try tryParseRateLimits(arena, line)) |p| return p;
        }
        if (nl) |p| line_end = p else break;
    }
    return error.NoTokenCount;
}

fn tryParseRateLimits(arena: std.mem.Allocator, line: []const u8) !?CodexProbe {
    // 快速过滤：不含 "token_count" 直接跳。
    if (std.mem.indexOf(u8, line, "\"token_count\"") == null) return null;
    if (std.mem.indexOf(u8, line, "\"rate_limits\"") == null) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) { .object => |o| o, else => return null };
    const payload = switch (root.get("payload") orelse return null) { .object => |o| o, else => return null };
    const ptype = switch (payload.get("type") orelse return null) { .string => |s| s, else => return null };
    if (!std.mem.eql(u8, ptype, "token_count")) return null;
    const rl_v = payload.get("rate_limits") orelse return null;
    if (rl_v != .object) return null;
    const rl = rl_v.object;

    var session_pct: ?u32 = null;
    var session_resets_ms: ?i64 = null;
    var weekly_pct: ?u32 = null;
    var weekly_resets_ms: ?i64 = null;
    var plan_dup: ?[]const u8 = null;

    if (rl.get("primary")) |pv| if (pv == .object) {
        session_pct = readUsedPct(pv.object);
        session_resets_ms = readResetsMs(pv.object);
    };
    if (rl.get("secondary")) |sv| if (sv == .object) {
        weekly_pct = readUsedPct(sv.object);
        weekly_resets_ms = readResetsMs(sv.object);
    };
    if (rl.get("plan_type")) |pt| if (pt == .string) {
        plan_dup = arena.dupe(u8, pt.string) catch null;
    };

    // 至少要有一边的 used_pct 才算 ok；纯 null 视为没数据。
    if (session_pct == null and weekly_pct == null) return null;

    return CodexProbe{
        .ok = true,
        .err = null,
        .source = "jsonl",
        .session_pct = session_pct,
        .session_resets_ms = session_resets_ms,
        .weekly_pct = weekly_pct,
        .weekly_resets_ms = weekly_resets_ms,
        .plan_type = plan_dup,
    };
}

fn readUsedPct(obj: std.json.ObjectMap) ?u32 {
    const v = obj.get("used_percent") orelse return null;
    return switch (v) {
        .integer => |i| @intCast(@max(0, @min(100, i))),
        .float => |f| @intFromFloat(@round(@max(0.0, @min(100.0, f)))),
        else => null,
    };
}

fn readResetsMs(obj: std.json.ObjectMap) ?i64 {
    // JSONL `resets_at` (plural) vs HTTP `reset_at` (singular) —— 同概念两个名。
    const v = obj.get("resets_at") orelse obj.get("reset_at") orelse return null;
    const secs: i64 = switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return null,
    };
    return secs * 1000;
}

// ── JSON serialization ────────────────────────────────────────────────

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

fn writeClaudeJson(buf: *Buf, alloc: std.mem.Allocator, p: Probe) !void {
    try buf.append(alloc, '{');
    try buf.print(alloc, "\"ok\":{s}", .{if (p.ok) "true" else "false"});
    if (p.err) |e| {
        try buf.appendSlice(alloc, ",\"error\":");
        try jsonString(buf, alloc, e);
    }
    try buf.appendSlice(alloc, ",\"session\":");
    try writeWindowJson(buf, alloc, p.session_pct, p.session_resets, p.session_resets_ms);
    try buf.appendSlice(alloc, ",\"weekly\":");
    try writeWindowJson(buf, alloc, p.weekly_pct, p.weekly_resets, p.weekly_resets_ms);
    if (p.total_cost_usd) |c| {
        try buf.print(alloc, ",\"total_cost_usd\":{d:.4}", .{c});
    } else {
        try buf.appendSlice(alloc, ",\"total_cost_usd\":null");
    }
    try buf.append(alloc, '}');
}

fn writeWindowJson(buf: *Buf, alloc: std.mem.Allocator, pct: ?u32, resets: ?[]const u8, resets_ms: ?i64) !void {
    try buf.append(alloc, '{');
    if (pct) |v| {
        try buf.print(alloc, "\"used_pct\":{d}", .{v});
    } else {
        try buf.appendSlice(alloc, "\"used_pct\":null");
    }
    try buf.appendSlice(alloc, ",\"resets_at_raw\":");
    if (resets) |r| try jsonString(buf, alloc, r) else try buf.appendSlice(alloc, "null");
    if (resets_ms) |ms| {
        try buf.print(alloc, ",\"resets_at_ms\":{d}", .{ms});
    } else {
        try buf.appendSlice(alloc, ",\"resets_at_ms\":null");
    }
    try buf.append(alloc, '}');
}

fn writeCodexJson(buf: *Buf, alloc: std.mem.Allocator, p: CodexProbe) !void {
    try buf.append(alloc, '{');
    try buf.print(alloc, "\"ok\":{s}", .{if (p.ok) "true" else "false"});
    if (p.err) |e| {
        try buf.appendSlice(alloc, ",\"error\":");
        try jsonString(buf, alloc, e);
    }
    try buf.appendSlice(alloc, ",\"source\":");
    try jsonString(buf, alloc, p.source);
    try buf.appendSlice(alloc, ",\"session\":");
    try writeWindowJson(buf, alloc, p.session_pct, null, p.session_resets_ms);
    try buf.appendSlice(alloc, ",\"weekly\":");
    try writeWindowJson(buf, alloc, p.weekly_pct, null, p.weekly_resets_ms);
    try buf.appendSlice(alloc, ",\"plan_type\":");
    if (p.plan_type) |s| try jsonString(buf, alloc, s) else try buf.appendSlice(alloc, "null");
    // credits 只 HTTP 路径有；jsonl fallback 全 null。
    try buf.appendSlice(alloc, ",\"credits\":{");
    try buf.appendSlice(alloc, "\"has\":");
    if (p.credits_has) |b| try buf.appendSlice(alloc, if (b) "true" else "false") else try buf.appendSlice(alloc, "null");
    try buf.appendSlice(alloc, ",\"unlimited\":");
    if (p.credits_unlimited) |b| try buf.appendSlice(alloc, if (b) "true" else "false") else try buf.appendSlice(alloc, "null");
    try buf.appendSlice(alloc, ",\"balance\":");
    if (p.credits_balance) |s| try jsonString(buf, alloc, s) else try buf.appendSlice(alloc, "null");
    try buf.append(alloc, '}');
    try buf.append(alloc, '}');
}

// Builds the full {"ts":..., "claude":{...}, "codex":{...}} object.
fn buildSample(alloc: std.mem.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const claude = probeClaude(arena);
    const codex = probeCodex(arena);
    var body: Buf = .empty;
    defer body.deinit(arena);
    try body.print(arena, "{{\"ts\":{d},\"claude\":", .{nowMs()});
    try writeClaudeJson(&body, arena, claude);
    try body.appendSlice(arena, ",\"codex\":");
    try writeCodexJson(&body, arena, codex);
    try body.append(arena, '}');

    // Copy into caller's allocator before arena deinits.
    return alloc.dupe(u8, body.items);
}

// ── Cache helpers ─────────────────────────────────────────────────────

fn cacheStore(json: []const u8) void {
    _ = pthread_mutex_lock(&cache_mu);
    defer _ = pthread_mutex_unlock(&cache_mu);
    if (cached_json) |old| cache_alloc.free(old);
    cached_json = cache_alloc.dupe(u8, json) catch null;
    cached_ts = nowMs();
}

fn cacheGetDup(alloc: std.mem.Allocator) ?[]u8 {
    _ = pthread_mutex_lock(&cache_mu);
    defer _ = pthread_mutex_unlock(&cache_mu);
    const cur = cached_json orelse return null;
    return alloc.dupe(u8, cur) catch null;
}

// ── Emitter (plugin mode) ─────────────────────────────────────────────

fn emitterLoop(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    while (true) {
        const json = buildSample(cache_alloc) catch {
            _ = usleep(interval_secs * 1_000_000);
            continue;
        };
        defer cache_alloc.free(json);
        cacheStore(json);

        var arena_state = std.heap.ArenaAllocator.init(cache_alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var body: Buf = .empty;
        defer body.deinit(arena);
        body.appendSlice(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"sample\",\"contents\":") catch {
            _ = usleep(interval_secs * 1_000_000);
            continue;
        };
        body.appendSlice(arena, json) catch {
            _ = usleep(interval_secs * 1_000_000);
            continue;
        };
        body.appendSlice(arena, "}}") catch {
            _ = usleep(interval_secs * 1_000_000);
            continue;
        };
        writeFramed(body.items) catch break;

        _ = usleep(interval_secs * 1_000_000);
    }
    return null;
}

fn startEmitter() void {
    if (emitter_started) return;
    var tid: pthread_t = undefined;
    if (pthread_create(&tid, null, emitterLoop, null) != 0) return;
    _ = pthread_detach(tid);
    emitter_started = true;
}

// ── MCP message handling ──────────────────────────────────────────────

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

fn handleMessage(arena: std.mem.Allocator, msg: []const u8) !void {
    const method = extractStringField(msg, "method") orelse return;
    const id = extractIdRaw(msg);

    if (std.mem.eql(u8, method, "initialize")) {
        var resp: Buf = .empty;
        defer resp.deinit(arena);
        try resp.print(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{\"listChanged\":false}}}},\"serverInfo\":{{\"name\":\"tokstat\",\"version\":\"0.1.0\"}}}}}}", .{id});
        try writeFramed(resp.items);
        // Kick off the background probe immediately so the first
        // snapshot tools/call doesn't block for 20s synchronously.
        startEmitter();
        return;
    }
    if (std.mem.eql(u8, method, "notifications/initialized")) return;
    if (std.mem.eql(u8, method, "resources/subscribe")) {
        startEmitter();
        var resp: Buf = .empty;
        defer resp.deinit(arena);
        try resp.print(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{id});
        try writeFramed(resp.items);
        return;
    }
    if (std.mem.eql(u8, method, "resources/unsubscribe")) {
        var resp: Buf = .empty;
        defer resp.deinit(arena);
        try resp.print(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{id});
        try writeFramed(resp.items);
        return;
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const tool = extractStringField(msg, "name") orelse {
            try writeError(arena, id, -32602, "missing tool name");
            return;
        };
        const inner: []u8 = blk: {
            if (std.mem.eql(u8, tool, "tokstat.snapshot")) {
                if (cacheGetDup(arena)) |c| break :blk c;
                // No cached value yet — fall through to a fresh probe.
            }
            if (std.mem.eql(u8, tool, "tokstat.snapshot") or
                std.mem.eql(u8, tool, "tokstat.refresh"))
            {
                const fresh = buildSample(arena) catch |e| {
                    try writeError(arena, id, -32603, @errorName(e));
                    return;
                };
                cacheStore(fresh);
                break :blk fresh;
            }
            try writeError(arena, id, -32601, "unknown tool");
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

// ── Entry points ──────────────────────────────────────────────────────

fn loadIntervalFromEnv() void {
    if (getenv("TOKSTAT_INTERVAL_SECS")) |raw| {
        const s = std.mem.span(raw);
        if (std.fmt.parseInt(u32, s, 10)) |v| {
            interval_secs = @max(v, interval_secs_floor);
        } else |_| {}
    }
}

fn runMcpLoop() !void {
    loadIntervalFromEnv();
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
            // Last-ditch: emit an unframed log line on stderr.
            var msg_buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&msg_buf, "tokstat handle error: {s}\n", .{@errorName(err)}) catch continue;
            _ = libcWrite(stderr_fd, m) catch {};
        };
    }
}

fn runJsonlMode() !void {
    const backing = std.heap.smp_allocator;
    while (true) {
        const json = try buildSample(backing);
        defer backing.free(json);
        _ = try libcWrite(stdout_fd, json);
        _ = try libcWrite(stdout_fd, "\n");
        _ = usleep(interval_secs * 1_000_000);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    tlog("=== tokstat start pid={d} ===", .{std.c.getpid()});
    var jsonl_mode = false;
    var once_mode = false;
    var it = init.args.iterate();
    _ = it.next(); // argv[0]
    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--jsonl")) {
            jsonl_mode = true;
        } else if (std.mem.eql(u8, arg, "--once")) {
            once_mode = true;
            jsonl_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--interval=")) {
            const v = std.fmt.parseInt(u32, arg["--interval=".len..], 10) catch interval_secs;
            interval_secs = @max(v, 1); // CLI mode lets you go below the plugin floor
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help =
                "tokstat — Claude usage probe\n" ++
                "Usage:\n" ++
                "  tokstat                # MCP stdio plugin mode (default)\n" ++
                "  tokstat --jsonl        # stream one JSON line per tick\n" ++
                "  tokstat --once         # single probe + exit\n" ++
                "  tokstat --interval=N   # seconds between probes\n";
            _ = libcWrite(stdout_fd, help) catch {};
            return;
        }
    }

    if (once_mode) {
        const backing = std.heap.smp_allocator;
        const json = try buildSample(backing);
        defer backing.free(json);
        _ = try libcWrite(stdout_fd, json);
        _ = try libcWrite(stdout_fd, "\n");
        return;
    }
    if (jsonl_mode) return runJsonlMode();
    return runMcpLoop();
}
