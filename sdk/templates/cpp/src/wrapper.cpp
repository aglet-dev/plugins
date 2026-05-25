// {{Id}} plugin — {{description}}
//
// Built on `aglet_plugin_sdk`: the SDK owns the alloc/free/dispatch wasm
// exports + JSON marshaling. This file holds only the action handlers and
// the dispatch entry point.

#include <aglet_plugin.h>

#include <string>
#include <string_view>

// ─── action handlers ────────────────────────────────────────────────────────

static std::string doEcho(const aglet::Params& p) {
    auto msg = p.strOr("msg", "(empty)");
    return aglet::Result::ok().str("echo", msg);
}

// ─── dispatch ────────────────────────────────────────────────────────────────

std::string aglet_dispatch_action(std::string_view action,
                                  std::string_view params_json) {
    aglet::Params p(params_json);
    if (action == "echo") return doEcho(p);
    return aglet::errUnknown(std::string("{{namespace}}.") + std::string(action));
}

AGLET_PLUGIN_EXPORTS
