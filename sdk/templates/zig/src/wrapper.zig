//! {{Id}} plugin — {{description}}
//!
//! Built on `aglet_plugin_sdk`: the SDK owns the alloc/free/dispatch wasm
//! exports + JSON marshaling. This file holds only the action handlers and
//! the dispatch table.

const std = @import("std");
const sdk = @import("aglet_plugin_sdk");

// ─── wasm exports ───────────────────────────────────────────────────────────

comptime { sdk.exportRuntime(); }

export fn dispatch(ap: u32, al: u32, pp: u32, pl: u32) callconv(.c) u64 {
    return sdk.runDispatch(Handlers, ap, al, pp, pl);
}

// ─── action handlers ────────────────────────────────────────────────────────
//
// Each `pub fn` here becomes an action callable as `{{namespace}}.<fn_name>`.
// The function signature is fixed: `(p: *sdk.Params) anyerror![]const u8`.

const Handlers = struct {
    pub fn echo(p: *sdk.Params) anyerror![]const u8 {
        const msg = p.str("msg") orelse "(empty)";
        return sdk.okStr(p.arena, "echo", msg);
    }
};
