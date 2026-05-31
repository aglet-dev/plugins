//! sysmon — host metrics over MCP stdio (zig native binary).
//!
//! Long-lived subprocess. CPU sampling holds prior-tick state between
//! tools/call invocations so each call returns a delta against the last
//! sample (vs. spawning fresh each tick — the whole point of stdio over
//! the static `sysinfo` plugin).
//!
//! macOS:
//!   memory: sysctlbyname("hw.memsize") + host_statistics64(HOST_VM_INFO64)
//!   cpu:    host_processor_info(PROCESSOR_CPU_LOAD_INFO) delta
//!   disk:   statfs()
//!
//! Linux: /proc/stat + /proc/meminfo + statvfs (v0.1 leaves as TODO; the
//! macOS path is enough for current dogfood — aglet-apps/sysmon).
//!
//! Wire: LSP-style Content-Length framing + MCP JSON-RPC subset
//! (initialize, tools/call). See aglet repo docs/STDIO_PLUGIN_SPEC.md.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const stdin_fd: posix.fd_t = 0;
const stdout_fd: posix.fd_t = 1;
const stderr_fd: posix.fd_t = 2;

// zig 0.16 std.posix dropped `write` (kept only `read`); call libc directly.
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn usleep(usec: c_uint) c_int;

// ── pthread bindings (zig 0.16 std.Thread has no Mutex) ───────────────
// Mirror the host's stdio_plugin Mutex pattern — the plugin needs to guard
// stdout writes between the main request/response loop and the background
// emitter thread.
const pthread_t = std.c.pthread_t;
const pthread_mutex_t = std.c.pthread_mutex_t;
extern "c" fn pthread_create(thread: *pthread_t, attr: ?*anyopaque, start_routine: *const fn (?*anyopaque) callconv(.c) ?*anyopaque, arg: ?*anyopaque) c_int;
extern "c" fn pthread_detach(thread: pthread_t) c_int;
extern "c" fn pthread_mutex_lock(m: *pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_unlock(m: *pthread_mutex_t) c_int;

var stdout_mu: pthread_mutex_t = .{};
var emitter_started: bool = false;

fn libcWrite(fd: posix.fd_t, buf: []const u8) !usize {
    const n = write(fd, buf.ptr, buf.len);
    if (n < 0) return error.WriteFailed;
    return @intCast(n);
}

// ── framing ───────────────────────────────────────────────────────────

fn readAll(buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try posix.read(stdin_fd, buf[got..]);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
}

fn writeAll(buf: []const u8) !void {
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
    // Guard stdout — the emitter thread (resources/subscribe) writes the
    // ticker notifications concurrently with the main loop's responses.
    _ = pthread_mutex_lock(&stdout_mu);
    defer _ = pthread_mutex_unlock(&stdout_mu);
    try writeAll(h);
    try writeAll(body);
}

// ── macOS Mach API bindings ───────────────────────────────────────────

const HOST_VM_INFO64: c_int = 4;
const HOST_VM_INFO64_COUNT: c_uint = 38; // natural_t count of vm_statistics64_data_t / 4
const PROCESSOR_CPU_LOAD_INFO: c_int = 2;
const CPU_STATE_USER: usize = 0;
const CPU_STATE_SYSTEM: usize = 1;
const CPU_STATE_IDLE: usize = 2;
const CPU_STATE_NICE: usize = 3;
const CPU_STATE_MAX: usize = 4;

const VmStatistics64 = extern struct {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u64,
    reactivations: u64,
    pageins: u64,
    pageouts: u64,
    faults: u64,
    cow_faults: u64,
    lookups: u64,
    hits: u64,
    purges: u64,
    purgeable_count: u32,
    speculative_count: u32,
    decompressions: u64,
    compressions: u64,
    swapins: u64,
    swapouts: u64,
    compressor_page_count: u32,
    throttled_count: u32,
    external_page_count: u32,
    internal_page_count: u32,
    total_uncompressed_pages_in_compressor: u64,
};

// macOS struct statfs (Darwin's <sys/mount.h>). Field layout is stable
// since 10.6. We only read f_bsize / f_blocks / f_bavail.
const StatfsDarwin = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_owner: u32,
    f_type: u32,
    f_flags: u32,
    f_fssubtype: u32,
    f_fstypename: [16]u8,
    f_mntonname: [1024]u8,
    f_mntfromname: [1024]u8,
    f_flags_ext: u32,
    f_reserved: [7]u32,
};

extern "c" fn mach_host_self() c_uint;
extern "c" fn host_statistics64(host: c_uint, flavor: c_int, info: [*]u8, count: *c_uint) c_int;
extern "c" fn host_processor_info(host: c_uint, flavor: c_int, out_count: *c_uint, info: *[*]c_int, info_count: *c_uint) c_int;
extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*const anyopaque, newlen: usize) c_int;
extern "c" fn statfs(path: [*:0]const u8, buf: *StatfsDarwin) c_int;
extern "c" fn vm_deallocate(target: c_uint, address: usize, size: usize) c_int;
extern "c" fn mach_task_self() c_uint;

const macos_page_size: u64 = 16384; // M-series. (4096 on Intel; close enough — fall back to sysctl below.)

// ── metrics ──────────────────────────────────────────────────────────

const CpuTotals = struct { user: u64, system: u64, idle: u64, nice: u64 };

var prior_cpu: ?CpuTotals = null;

fn sampleCpuTotals() !CpuTotals {
    var n_cpus: c_uint = 0;
    var info_ptr: [*]c_int = undefined;
    var info_count: c_uint = 0;
    const rc = host_processor_info(
        mach_host_self(),
        PROCESSOR_CPU_LOAD_INFO,
        &n_cpus,
        &info_ptr,
        &info_count,
    );
    if (rc != 0) return error.HostProcessorInfoFailed;
    defer _ = vm_deallocate(mach_task_self(), @intFromPtr(info_ptr), info_count * @sizeOf(c_int));

    var totals = CpuTotals{ .user = 0, .system = 0, .idle = 0, .nice = 0 };
    var i: usize = 0;
    while (i < n_cpus) : (i += 1) {
        const base = i * CPU_STATE_MAX;
        totals.user += @intCast(info_ptr[base + CPU_STATE_USER]);
        totals.system += @intCast(info_ptr[base + CPU_STATE_SYSTEM]);
        totals.idle += @intCast(info_ptr[base + CPU_STATE_IDLE]);
        totals.nice += @intCast(info_ptr[base + CPU_STATE_NICE]);
    }
    return totals;
}

const CpuSample = struct {
    used_pct: f64,
    user_pct: f64,
    sys_pct: f64,
    idle_pct: f64,
};

fn cpuSample() CpuSample {
    const now = sampleCpuTotals() catch {
        return .{ .used_pct = 0, .user_pct = 0, .sys_pct = 0, .idle_pct = 100 };
    };
    defer prior_cpu = now;
    const prev = prior_cpu orelse {
        // First call after spawn: no delta yet — return zeros + idle 100,
        // caller's second tick will get real numbers.
        return .{ .used_pct = 0, .user_pct = 0, .sys_pct = 0, .idle_pct = 100 };
    };
    const du = now.user - prev.user;
    const ds = now.system - prev.system;
    const di = now.idle - prev.idle;
    const dn = now.nice - prev.nice;
    const total = du + ds + di + dn;
    if (total == 0) return .{ .used_pct = 0, .user_pct = 0, .sys_pct = 0, .idle_pct = 100 };
    const tf: f64 = @floatFromInt(total);
    return .{
        .used_pct = 100.0 * @as(f64, @floatFromInt(du + ds + dn)) / tf,
        .user_pct = 100.0 * @as(f64, @floatFromInt(du + dn)) / tf,
        .sys_pct = 100.0 * @as(f64, @floatFromInt(ds)) / tf,
        .idle_pct = 100.0 * @as(f64, @floatFromInt(di)) / tf,
    };
}

const MemorySample = struct {
    used_bytes: u64,
    total_bytes: u64,
    used_pct: f64,
};

fn memSample() MemorySample {
    var total_bytes: u64 = 0;
    var total_len: usize = @sizeOf(u64);
    _ = sysctlbyname("hw.memsize", &total_bytes, &total_len, null, 0);

    var page_size: u64 = macos_page_size;
    var ps_len: usize = @sizeOf(u64);
    if (sysctlbyname("hw.pagesize", &page_size, &ps_len, null, 0) != 0) {
        page_size = macos_page_size;
    }

    var vm: VmStatistics64 = undefined;
    var count: c_uint = HOST_VM_INFO64_COUNT;
    const rc = host_statistics64(
        mach_host_self(),
        HOST_VM_INFO64,
        @ptrCast(&vm),
        &count,
    );
    if (rc != 0) return .{ .used_bytes = 0, .total_bytes = total_bytes, .used_pct = 0 };

    // macOS "Memory Used" (matches Activity Monitor) = wired + active +
    // compressed. Speculative is reclaimable; don't count it.
    const used_pages: u64 = @as(u64, vm.wire_count) +
        @as(u64, vm.active_count) +
        @as(u64, vm.compressor_page_count);
    const used = used_pages * page_size;
    const pct: f64 = if (total_bytes == 0) 0 else 100.0 * @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(total_bytes));
    return .{ .used_bytes = used, .total_bytes = total_bytes, .used_pct = pct };
}

const DiskSample = struct {
    used_bytes: u64,
    total_bytes: u64,
    free_bytes: u64,
    used_pct: f64,
};

fn diskSample(path_buf: [*:0]const u8) DiskSample {
    var sf: StatfsDarwin = undefined;
    if (statfs(path_buf, &sf) != 0) {
        return .{ .used_bytes = 0, .total_bytes = 0, .free_bytes = 0, .used_pct = 0 };
    }
    const total = sf.f_blocks * sf.f_bsize;
    const free = sf.f_bavail * sf.f_bsize;
    const used = total -| free;
    const pct: f64 = if (total == 0) 0 else 100.0 * @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(total));
    return .{ .used_bytes = used, .total_bytes = total, .free_bytes = free, .used_pct = pct };
}

// ── JSON helpers (just enough for our wire shape) ─────────────────────
//
// zig 0.16 ArrayList is unmanaged; the allocator is passed per-call. Helpers
// take `*std.ArrayList(u8)` + allocator rather than a writer adapter.

const Buf = std.ArrayList(u8);

fn jsonNumber(buf: *Buf, alloc: std.mem.Allocator, v: f64) !void {
    // Two-decimal precision is plenty for the UI (bar % / sparkline).
    try buf.print(alloc, "{d:.2}", .{v});
}

fn writeCpuJson(buf: *Buf, alloc: std.mem.Allocator, s: CpuSample) !void {
    try buf.appendSlice(alloc, "{\"used_pct\":");
    try jsonNumber(buf, alloc, s.used_pct);
    try buf.appendSlice(alloc, ",\"user_pct\":");
    try jsonNumber(buf, alloc, s.user_pct);
    try buf.appendSlice(alloc, ",\"sys_pct\":");
    try jsonNumber(buf, alloc, s.sys_pct);
    try buf.appendSlice(alloc, ",\"idle_pct\":");
    try jsonNumber(buf, alloc, s.idle_pct);
    try buf.append(alloc, '}');
}

fn writeMemJson(buf: *Buf, alloc: std.mem.Allocator, s: MemorySample) !void {
    try buf.print(alloc, "{{\"used_bytes\":{d},\"total_bytes\":{d},\"used_pct\":", .{ s.used_bytes, s.total_bytes });
    try jsonNumber(buf, alloc, s.used_pct);
    try buf.append(alloc, '}');
}

fn writeDiskJson(buf: *Buf, alloc: std.mem.Allocator, s: DiskSample) !void {
    try buf.print(alloc, "{{\"used_bytes\":{d},\"total_bytes\":{d},\"free_bytes\":{d},\"used_pct\":", .{ s.used_bytes, s.total_bytes, s.free_bytes });
    try jsonNumber(buf, alloc, s.used_pct);
    try buf.append(alloc, '}');
}

// ── battery + GPU via IOKit / CoreFoundation (macOS) ──────────────────────
//
// battery: IOPSCopyPowerSourcesInfo + IOPSGetPowerSourceDescription → CF dict
//          ("Current Capacity"/"Max Capacity"/"Is Charging"/"Power Source
//          State"/"Time to Empty|Full")。台式机无电源 → present=false。
// gpu:     IOServiceMatching("IOAccelerator") → IORegistryEntryCreateCFProperty
//          ("PerformanceStatistics") → "Device Utilization %" + "In use system
//          memory"。本机已验证这些键存在（公开 IORegistry，非私有 framework）。
// 链 IOKit + CoreFoundation framework（build.zig，仅 macOS）。

const BatterySample = struct {
    present: bool = false,
    percent: f64 = 0,
    charging: bool = false,
    power_source: []const u8 = "Unknown", // "AC Power" | "Battery Power"
    time_remaining_min: i64 = -1, // -1 = 计算中/未知
};
const GpuSample = struct { util_pct: f64 = 0, mem_used_bytes: u64 = 0 };

const CFRef = ?*anyopaque;
const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCFNumberSInt64Type: c_int = 4;

extern "c" fn CFRelease(cf: CFRef) void;
extern "c" fn CFArrayGetCount(arr: CFRef) c_long;
extern "c" fn CFArrayGetValueAtIndex(arr: CFRef, idx: c_long) CFRef;
extern "c" fn CFDictionaryGetValue(dict: CFRef, key: ?*const anyopaque) ?*const anyopaque;
extern "c" fn CFStringCreateWithCString(alloc: CFRef, cstr: [*:0]const u8, enc: u32) CFRef;
extern "c" fn CFNumberGetValue(num: ?*const anyopaque, theType: c_int, valuePtr: *anyopaque) bool;
extern "c" fn CFBooleanGetValue(b: ?*const anyopaque) bool;
extern "c" fn CFGetTypeID(cf: ?*const anyopaque) c_ulong;
extern "c" fn CFNumberGetTypeID() c_ulong;
extern "c" fn CFBooleanGetTypeID() c_ulong;
extern "c" fn CFStringGetTypeID() c_ulong;
extern "c" fn CFStringGetCString(s: ?*const anyopaque, buf: [*]u8, sz: c_long, enc: u32) bool;

extern "c" fn IOPSCopyPowerSourcesInfo() CFRef;
extern "c" fn IOPSCopyPowerSourcesList(blob: CFRef) CFRef;
extern "c" fn IOPSGetPowerSourceDescription(blob: CFRef, ps: CFRef) CFRef;

extern "c" fn IOServiceMatching(name: [*:0]const u8) CFRef;
extern "c" fn IOServiceGetMatchingServices(mainPort: c_uint, matching: CFRef, existing: *c_uint) c_int;
extern "c" fn IOIteratorNext(iterator: c_uint) c_uint;
extern "c" fn IORegistryEntryCreateCFProperty(entry: c_uint, key: CFRef, allocator: CFRef, options: u32) CFRef;
extern "c" fn IOObjectRelease(object: c_uint) c_int;

/// dict[key] → f64（CFNumber）。缺/类型不符 → null。
fn cfDictNum(dict: CFRef, key: [*:0]const u8) ?f64 {
    const k = CFStringCreateWithCString(null, key, kCFStringEncodingUTF8) orelse return null;
    defer CFRelease(k);
    const v = CFDictionaryGetValue(dict, k) orelse return null;
    if (CFGetTypeID(v) != CFNumberGetTypeID()) return null;
    var out: i64 = 0;
    if (!CFNumberGetValue(v, kCFNumberSInt64Type, &out)) return null;
    return @floatFromInt(out);
}

/// dict[key] → bool（CFBoolean）。
fn cfDictBool(dict: CFRef, key: [*:0]const u8) ?bool {
    const k = CFStringCreateWithCString(null, key, kCFStringEncodingUTF8) orelse return null;
    defer CFRelease(k);
    const v = CFDictionaryGetValue(dict, k) orelse return null;
    if (CFGetTypeID(v) != CFBooleanGetTypeID()) return null;
    return CFBooleanGetValue(v);
}

/// "Power Source State" → 归一成 "AC Power"/"Battery Power"。
fn cfDictPowerState(dict: CFRef) []const u8 {
    const k = CFStringCreateWithCString(null, "Power Source State", kCFStringEncodingUTF8) orelse return "Unknown";
    defer CFRelease(k);
    const v = CFDictionaryGetValue(dict, k) orelse return "Unknown";
    if (CFGetTypeID(v) != CFStringGetTypeID()) return "Unknown";
    var buf: [64]u8 = undefined;
    if (!CFStringGetCString(v, &buf, buf.len, kCFStringEncodingUTF8)) return "Unknown";
    const s = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&buf)), 0);
    if (std.mem.indexOf(u8, s, "AC") != null) return "AC Power";
    if (std.mem.indexOf(u8, s, "Battery") != null) return "Battery Power";
    return "Unknown";
}

fn batterySample() BatterySample {
    if (builtin.os.tag != .macos) return .{}; // present=false on non-macOS (v1)
    const blob = IOPSCopyPowerSourcesInfo() orelse return .{};
    defer CFRelease(blob);
    const list = IOPSCopyPowerSourcesList(blob) orelse return .{};
    defer CFRelease(list);
    if (CFArrayGetCount(list) == 0) return .{}; // 台式机无电源 → present=false
    const ps = CFArrayGetValueAtIndex(list, 0);
    const desc = IOPSGetPowerSourceDescription(blob, ps) orelse return .{};
    const cur = cfDictNum(desc, "Current Capacity") orelse 0;
    const max = cfDictNum(desc, "Max Capacity") orelse 100;
    const pct = if (max > 0) 100.0 * cur / max else cur;
    const charging = cfDictBool(desc, "Is Charging") orelse false;
    const ttf = cfDictNum(desc, "Time to Full") orelse -1;
    const tte = cfDictNum(desc, "Time to Empty") orelse -1;
    const remaining: f64 = if (charging) ttf else tte;
    return .{
        .present = true,
        .percent = pct,
        .charging = charging,
        .power_source = cfDictPowerState(desc),
        .time_remaining_min = if (remaining >= 0) @intFromFloat(remaining) else -1,
    };
}

fn gpuSample() GpuSample {
    if (builtin.os.tag != .macos) return .{};
    const matching = IOServiceMatching("IOAccelerator") orelse return .{};
    var iter: c_uint = 0;
    // 注意：IOServiceGetMatchingServices 消费 matching dict，不要再 release。
    if (IOServiceGetMatchingServices(0, matching, &iter) != 0) return .{};
    defer _ = IOObjectRelease(iter);
    var best: GpuSample = .{};
    while (true) {
        const svc = IOIteratorNext(iter);
        if (svc == 0) break;
        defer _ = IOObjectRelease(svc);
        const key = CFStringCreateWithCString(null, "PerformanceStatistics", kCFStringEncodingUTF8) orelse continue;
        defer CFRelease(key);
        const perf = IORegistryEntryCreateCFProperty(svc, key, null, 0) orelse continue;
        defer CFRelease(perf);
        const util = cfDictNum(perf, "Device Utilization %") orelse continue;
        const mem = cfDictNum(perf, "In use system memory") orelse 0;
        // 多 GPU 取利用率最高的（集显/独显）。
        if (util >= best.util_pct) best = .{ .util_pct = util, .mem_used_bytes = @intFromFloat(@max(mem, 0)) };
    }
    return best;
}

fn writeBatteryJson(buf: *Buf, alloc: std.mem.Allocator, s: BatterySample) !void {
    try buf.print(alloc, "{{\"present\":{},\"percent\":", .{s.present});
    try jsonNumber(buf, alloc, s.percent);
    try buf.print(alloc, ",\"charging\":{},\"power_source\":\"{s}\",\"time_remaining_min\":{d}}}", .{ s.charging, s.power_source, s.time_remaining_min });
}

fn writeGpuJson(buf: *Buf, alloc: std.mem.Allocator, s: GpuSample) !void {
    try buf.appendSlice(alloc, "{\"util_pct\":");
    try jsonNumber(buf, alloc, s.util_pct);
    try buf.print(alloc, ",\"mem_used_bytes\":{d}}}", .{s.mem_used_bytes});
}

// Build the inner JSON value (cpu/memory/disk or snapshot envelope) into
// the arena buffer. Caller wraps with MCP envelope.
fn buildToolResult(
    arena: std.mem.Allocator,
    tool: []const u8,
    disk_path: [*:0]const u8,
) ![]u8 {
    var out: Buf = .empty;
    defer out.deinit(arena);
    if (std.mem.eql(u8, tool, "sysmon.snapshot")) {
        try out.appendSlice(arena, "{\"cpu\":");
        try writeCpuJson(&out, arena, cpuSample());
        try out.appendSlice(arena, ",\"memory\":");
        try writeMemJson(&out, arena, memSample());
        try out.appendSlice(arena, ",\"disk\":");
        try writeDiskJson(&out, arena, diskSample(disk_path));
        try out.appendSlice(arena, ",\"battery\":");
        try writeBatteryJson(&out, arena, batterySample());
        try out.appendSlice(arena, ",\"gpu\":");
        try writeGpuJson(&out, arena, gpuSample());
        try out.append(arena, '}');
    } else if (std.mem.eql(u8, tool, "sysmon.cpu")) {
        try writeCpuJson(&out, arena, cpuSample());
    } else if (std.mem.eql(u8, tool, "sysmon.memory")) {
        try writeMemJson(&out, arena, memSample());
    } else if (std.mem.eql(u8, tool, "sysmon.disk")) {
        try writeDiskJson(&out, arena, diskSample(disk_path));
    } else if (std.mem.eql(u8, tool, "sysmon.battery")) {
        try writeBatteryJson(&out, arena, batterySample());
    } else if (std.mem.eql(u8, tool, "sysmon.gpu")) {
        try writeGpuJson(&out, arena, gpuSample());
    } else {
        return error.UnknownTool;
    }
    return out.toOwnedSlice(arena);
}

// ── MCP message handling ──────────────────────────────────────────────

fn extractStringField(json: []const u8, key: []const u8) ?[]const u8 {
    // Minimal scanner: find `"<key>"` then the next `"..."` value. Good
    // enough for our incoming shape (id is numeric, method/name are
    // simple strings, no escapes in the values we care about).
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
    // Return the id verbatim (number or string). Defaults to `null` if
    // absent so notifications don't echo an id back.
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

// ── ticker emitter ────────────────────────────────────────────────────
//
// Spawned on first resources/subscribe (uri="cpu"). Emits a
// notifications/resources/updated frame every ~1s with the latest CPU
// sample. v1: emit unconditionally for the process lifetime; no
// unsubscribe handling. Reentry-safe via the `emitter_started` flag.

fn emitterLoop(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    const backing = std.heap.smp_allocator;
    while (true) {
        _ = usleep(1_000_000); // 1s
        var arena_state = std.heap.ArenaAllocator.init(backing);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const sample = cpuSample();
        var body: Buf = .empty;
        defer body.deinit(arena);
        body.appendSlice(arena,
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"cpu\",\"contents\":") catch continue;
        writeCpuJson(&body, arena, sample) catch continue;
        body.appendSlice(arena, "}}") catch continue;
        writeFramed(body.items) catch break;
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

fn handleMessage(arena: std.mem.Allocator, msg: []const u8) !void {
    const method = extractStringField(msg, "method") orelse return;
    const id = extractIdRaw(msg);

    if (std.mem.eql(u8, method, "initialize")) {
        var resp: Buf = .empty;
        defer resp.deinit(arena);
        try resp.print(arena,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{\"listChanged\":false}}}},\"serverInfo\":{{\"name\":\"sysmon\",\"version\":\"0.2.0\"}}}}}}",
            .{id},
        );
        try writeFramed(resp.items);
        return;
    }
    if (std.mem.eql(u8, method, "notifications/initialized")) return;
    if (std.mem.eql(u8, method, "resources/subscribe")) {
        // Spawn the emitter thread (idempotent) and ack. We don't track
        // per-URI subscribers — first subscribe to any URI starts the
        // single global ticker on "cpu".
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
        // `path` arg for disk. Default to "/".
        var path_buf: [1024]u8 = undefined;
        const path_z: [*:0]const u8 = blk: {
            if (extractStringField(msg, "path")) |p| {
                if (p.len < path_buf.len) {
                    @memcpy(path_buf[0..p.len], p);
                    path_buf[p.len] = 0;
                    break :blk @ptrCast(&path_buf);
                }
            }
            path_buf[0] = '/';
            path_buf[1] = 0;
            break :blk @ptrCast(&path_buf);
        };

        const inner = buildToolResult(arena, tool, path_z) catch |e| {
            try writeError(arena, id, -32601, @errorName(e));
            return;
        };

        // MCP tools/call result envelope.
        var resp: Buf = .empty;
        defer resp.deinit(arena);
        try resp.print(arena,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":",
            .{id},
        );
        try writeJsonString(&resp, arena, inner);
        try resp.appendSlice(arena, "}],\"isError\":false}}");
        try writeFramed(resp.items);
        return;
    }
    // Unknown method.
    try writeError(arena, id, -32601, "method not found");
}

fn writeJsonString(buf: *Buf, alloc: std.mem.Allocator, s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(alloc, "\\\""),
        '\\' => try buf.appendSlice(alloc, "\\\\"),
        '\n' => try buf.appendSlice(alloc, "\\n"),
        '\r' => try buf.appendSlice(alloc, "\\r"),
        '\t' => try buf.appendSlice(alloc, "\\t"),
        else => try buf.append(alloc, c),
    };
    try buf.append(alloc, '"');
}

fn writeError(arena: std.mem.Allocator, id: []const u8, code: i32, message: []const u8) !void {
    var resp: Buf = .empty;
    defer resp.deinit(arena);
    try resp.print(arena,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":",
        .{ id, code },
    );
    try writeJsonString(&resp, arena, message);
    try resp.appendSlice(arena, "}}");
    try writeFramed(resp.items);
}

// ── main ─────────────────────────────────────────────────────────────

pub fn main() !void {
    if (builtin.os.tag != .macos) {
        // Linux path is a TODO — current dogfood (aglet-apps/sysmon) is
        // macOS-only, so we ship the macOS-first cut and fail loud on
        // other platforms rather than silently returning zeros.
        const msg = "sysmon: only macOS supported in v0.1.0 (Linux path is TODO)\n";
        _ = libcWrite(stderr_fd,msg) catch {};
        std.process.exit(1);
    }
    // Prime CPU prior-tick state so the first sample is meaningful.
    prior_cpu = sampleCpuTotals() catch null;

    const backing = std.heap.smp_allocator;

    while (true) {
        var arena_state = std.heap.ArenaAllocator.init(backing);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const msg = readFramed(arena) catch break;
        handleMessage(arena, msg) catch |e| {
            const what = @errorName(e);
            _ = libcWrite(stderr_fd,"sysmon: handle error: ") catch {};
            _ = libcWrite(stderr_fd,what) catch {};
            _ = libcWrite(stderr_fd,"\n") catch {};
        };
    }
}
