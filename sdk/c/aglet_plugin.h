// Aglet plugin SDK — C/C++ (emscripten, wasm32).
//
// Header-only library that removes the marshaling boilerplate shared by every
// emscripten-built Aglet plugin: ABI exports, JSON parsing, base64, error
// envelopes, dispatch trampoline. A complete plugin looks like:
//
//     #include <aglet_plugin.h>
//     #include <string>
//     #include <string_view>
//
//     static std::string doEcho(const aglet::Params& p) {
//         auto msg = p.str("msg").value_or("(empty)");
//         return aglet::Result::ok().str("echo", msg);
//     }
//
//     std::string aglet_dispatch_action(std::string_view action,
//                                       std::string_view params_json) {
//         aglet::Params p(params_json);
//         if (action == "echo") return doEcho(p);
//         return aglet::errUnknown(action);
//     }
//
//     AGLET_PLUGIN_EXPORTS
//
// ABI contract (host ↔ plugin):
//   - The plugin exports `alloc(len) -> ptr`, `free(ptr, len)`, and
//     `dispatch(action_ptr, action_len, params_ptr, params_len) -> u64`.
//   - `dispatch` returns a packed `(ptr << 32) | len` referring to a buffer
//     in the plugin's linear memory; the host reads it and then calls `free`.
//   - The buffer contents are JSON: either `{"ok":true, ...}` or
//     `{"ok":false, "error":{"code","message"}}`. Binary payloads are
//     standard-base64 strings under `<key>_b64` field names.
//
// Build: header-only. Add `sdk/c/` to your plugin's include path. With CMake,
// link the `aglet_plugin_sdk_c` INTERFACE target defined in `sdk/c/CMakeLists.txt`.
//
// Requires C++17 (std::string_view, std::optional, structured bindings).

#ifndef AGLET_PLUGIN_H
#define AGLET_PLUGIN_H

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace aglet {

// ─── base64 ──────────────────────────────────────────────────────────────────

namespace detail {
inline constexpr char kB64Chars[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
}

inline std::string encodeB64(const uint8_t* data, size_t len) {
    std::string out;
    out.reserve(((len + 2) / 3) * 4);
    size_t i = 0;
    while (i + 3 <= len) {
        uint32_t n = (uint32_t(data[i]) << 16)
                   | (uint32_t(data[i + 1]) << 8)
                   |  uint32_t(data[i + 2]);
        out.push_back(detail::kB64Chars[(n >> 18) & 63]);
        out.push_back(detail::kB64Chars[(n >> 12) & 63]);
        out.push_back(detail::kB64Chars[(n >> 6) & 63]);
        out.push_back(detail::kB64Chars[n & 63]);
        i += 3;
    }
    if (i < len) {
        uint32_t n = uint32_t(data[i]) << 16;
        if (i + 1 < len) n |= uint32_t(data[i + 1]) << 8;
        out.push_back(detail::kB64Chars[(n >> 18) & 63]);
        out.push_back(detail::kB64Chars[(n >> 12) & 63]);
        out.push_back(i + 1 < len ? detail::kB64Chars[(n >> 6) & 63] : '=');
        out.push_back('=');
    }
    return out;
}

inline std::string encodeB64(std::string_view bytes) {
    return encodeB64(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size());
}

inline std::vector<uint8_t> decodeB64(std::string_view s) {
    int rev[256];
    for (int i = 0; i < 256; i++) rev[i] = -1;
    for (int i = 0; i < 64; i++) rev[static_cast<int>(detail::kB64Chars[i])] = i;
    std::vector<uint8_t> out;
    out.reserve((s.size() * 3) / 4);
    int bits = 0, nbits = 0;
    for (char c : s) {
        if (c == '=' || c == '\n' || c == '\r' || c == ' ' || c == '\t') continue;
        int v = rev[static_cast<unsigned char>(c)];
        if (v < 0) continue;
        bits = (bits << 6) | v;
        nbits += 6;
        if (nbits >= 8) {
            nbits -= 8;
            out.push_back(static_cast<uint8_t>((bits >> nbits) & 0xFF));
        }
    }
    return out;
}

// ─── JSON helpers ────────────────────────────────────────────────────────────
//
// Lightweight key-based scanners. Suitable for the shallow JSON shapes used by
// Aglet plugin params (typed by `aplugin.json` schema, no nested key conflicts).
// Not a general-purpose JSON parser.

namespace detail {

inline bool jsonFindKey(std::string_view s, std::string_view key, size_t& value_start) {
    std::string needle;
    needle.reserve(key.size() + 2);
    needle.push_back('"');
    needle.append(key.data(), key.size());
    needle.push_back('"');
    size_t i = s.find(needle);
    if (i == std::string_view::npos) return false;
    i += needle.size();
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == ':')) i++;
    value_start = i;
    return true;
}

inline std::optional<std::string> jsonGetString(std::string_view s, std::string_view key) {
    size_t i;
    if (!jsonFindKey(s, key, i) || i >= s.size() || s[i] != '"') return std::nullopt;
    i++;
    std::string out;
    while (i < s.size() && s[i] != '"') {
        if (s[i] == '\\' && i + 1 < s.size()) {
            char c = s[i + 1];
            switch (c) {
                case 'n':  out.push_back('\n'); break;
                case 't':  out.push_back('\t'); break;
                case 'r':  out.push_back('\r'); break;
                case '"':  out.push_back('"');  break;
                case '\\': out.push_back('\\'); break;
                case '/':  out.push_back('/');  break;
                default:   out.push_back(c);    break;
            }
            i += 2;
        } else {
            out.push_back(s[i++]);
        }
    }
    return out;
}

inline std::optional<int64_t> jsonGetInt(std::string_view s, std::string_view key) {
    size_t i;
    if (!jsonFindKey(s, key, i)) return std::nullopt;
    bool neg = false;
    if (i < s.size() && s[i] == '-') { neg = true; i++; }
    int64_t v = 0;
    bool any = false;
    while (i < s.size() && s[i] >= '0' && s[i] <= '9') {
        v = v * 10 + (s[i++] - '0');
        any = true;
    }
    if (!any) return std::nullopt;
    return neg ? -v : v;
}

inline std::optional<bool> jsonGetBool(std::string_view s, std::string_view key) {
    size_t i;
    if (!jsonFindKey(s, key, i)) return std::nullopt;
    if (s.compare(i, 4, "true") == 0)  return true;
    if (s.compare(i, 5, "false") == 0) return false;
    return std::nullopt;
}

/// Locate a JSON array value at `key` and return [start, end) indices pointing
/// to the contents inside `[ ... ]`. Returns std::nullopt if not found / not an array.
inline std::optional<std::pair<size_t, size_t>> jsonFindArray(std::string_view s, std::string_view key) {
    size_t i;
    if (!jsonFindKey(s, key, i) || i >= s.size() || s[i] != '[') return std::nullopt;
    int depth = 1;
    size_t j = i + 1;
    size_t inside_start = j;
    while (j < s.size() && depth > 0) {
        char c = s[j];
        if (c == '[') depth++;
        else if (c == ']') depth--;
        else if (c == '"') {
            j++;
            while (j < s.size() && s[j] != '"') {
                if (s[j] == '\\' && j + 1 < s.size()) j++;
                j++;
            }
        }
        if (depth == 0) break;
        j++;
    }
    if (depth != 0) return std::nullopt;
    return std::make_pair(inside_start, j);
}

inline std::string jsonEscape(std::string_view s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(c));
                    out += buf;
                } else {
                    out.push_back(c);
                }
        }
    }
    return out;
}

} // namespace detail

inline std::string jsonEscape(std::string_view s) { return detail::jsonEscape(s); }

// ─── Params: typed input reader ──────────────────────────────────────────────

class Params {
public:
    explicit Params(std::string_view raw) : raw_(raw) {}

    /// String field — std::nullopt if missing or wrong type.
    std::optional<std::string> str(std::string_view key) const {
        return detail::jsonGetString(raw_, key);
    }

    /// String field with default — convenient when the field is optional.
    std::string strOr(std::string_view key, std::string_view default_value) const {
        if (auto v = str(key)) return *v;
        return std::string(default_value);
    }

    /// Integer field with default.
    int64_t integer(std::string_view key, int64_t default_value = 0) const {
        if (auto v = detail::jsonGetInt(raw_, key)) return *v;
        return default_value;
    }

    /// Boolean field — std::nullopt if missing.
    std::optional<bool> boolean(std::string_view key) const {
        return detail::jsonGetBool(raw_, key);
    }

    /// Base64-decoded bytes from `<key>` field. Returns empty vector if the
    /// key is missing or holds an invalid base64 string.
    std::vector<uint8_t> bytes(std::string_view key) const {
        if (auto v = str(key)) return decodeB64(*v);
        return {};
    }

    /// Raw `[start, end)` over an array value, suitable for hand-walking
    /// nested entries. Returns std::nullopt if missing.
    std::optional<std::pair<size_t, size_t>> findArray(std::string_view key) const {
        return detail::jsonFindArray(raw_, key);
    }

    /// The underlying JSON text, in case the plugin needs custom scanning.
    std::string_view raw() const { return raw_; }

private:
    std::string_view raw_;
};

// ─── Result builders ─────────────────────────────────────────────────────────
//
// Two flavors:
//   1. Free functions for single-field results: `aglet::okStr("digest", "...")`.
//   2. `Result::ok()` builder for multi-field results, chained with
//      `.str(...).integer(...).bytes(...)` and implicitly convertible to string.
//
// Binary payloads must already be base64-encoded when passed to `str(...)`,
// or use `.bytes(...)` which encodes a byte slice for you.

class Result {
public:
    /// `{"ok":true, "data":{ ... }}` envelope. Fields added via the chained
    /// methods land inside the `data` object — this matches the host runtime
    /// convention (`aglet.bridge` returns `resp.data` to the JS caller).
    static Result ok() {
        Result r;
        r.buf_ = R"({"ok":true,"data":{)";
        r.first_field_ = true;
        return r;
    }

    /// `{"ok":false,"error":{"code":..., "message":...}}` envelope.
    static Result err(std::string_view code, std::string_view message) {
        Result r;
        r.buf_ = R"({"ok":false,"error":{"code":")";
        r.buf_ += detail::jsonEscape(code);
        r.buf_ += R"(","message":")";
        r.buf_ += detail::jsonEscape(message);
        r.buf_ += R"("}})";
        r.closed_ = true;
        return r;
    }

    Result& str(std::string_view key, std::string_view value) {
        prepKey(key);
        buf_.push_back('"');
        buf_ += detail::jsonEscape(value);
        buf_.push_back('"');
        return *this;
    }

    Result& integer(std::string_view key, int64_t value) {
        prepKey(key);
        char tmp[24];
        std::snprintf(tmp, sizeof(tmp), "%lld", static_cast<long long>(value));
        buf_ += tmp;
        return *this;
    }

    Result& boolean(std::string_view key, bool value) {
        prepKey(key);
        buf_ += (value ? "true" : "false");
        return *this;
    }

    /// Add a `<key>` field whose value is the base64 encoding of `[data, data+len)`.
    /// By Aglet convention the key should end in `_b64` to signal the encoding.
    Result& bytes(std::string_view key, const uint8_t* data, size_t len) {
        prepKey(key);
        buf_.push_back('"');
        buf_ += encodeB64(data, len);
        buf_.push_back('"');
        return *this;
    }

    Result& bytes(std::string_view key, const std::vector<uint8_t>& v) {
        return bytes(key, v.data(), v.size());
    }

    /// Add a field whose value is a pre-encoded JSON fragment (array, object,
    /// nested envelope, etc.). The caller is responsible for valid JSON.
    Result& raw(std::string_view key, std::string_view json_value) {
        prepKey(key);
        buf_.append(json_value.data(), json_value.size());
        return *this;
    }

    /// Finalize and return the JSON string. Subsequent calls return the same
    /// finalized value.
    std::string build() {
        if (!closed_) {
            buf_ += "}}"; // close `data` then envelope
            closed_ = true;
        }
        return buf_;
    }

    /// Implicit conversion lets `return aglet::Result::ok().str(...);` work directly.
    operator std::string() { return build(); }

private:
    Result() = default;

    void prepKey(std::string_view key) {
        if (first_field_) {
            first_field_ = false;
        } else {
            buf_.push_back(',');
        }
        buf_.push_back('"');
        buf_ += detail::jsonEscape(key);
        buf_ += "\":";
    }

    std::string buf_;
    bool first_field_ = false;
    bool closed_ = false;
};

// Convenience single-field result builders.

inline std::string okStr(std::string_view key, std::string_view value) {
    return Result::ok().str(key, value);
}

inline std::string okInt(std::string_view key, int64_t value) {
    return Result::ok().integer(key, value);
}

inline std::string okBool(std::string_view key, bool value) {
    return Result::ok().boolean(key, value);
}

inline std::string okBytes(std::string_view key, const uint8_t* data, size_t len) {
    return Result::ok().bytes(key, data, len);
}

inline std::string okBytes(std::string_view key, const std::vector<uint8_t>& v) {
    return okBytes(key, v.data(), v.size());
}

// ─── Error envelopes ─────────────────────────────────────────────────────────

inline std::string err(std::string_view code, std::string_view message) {
    return Result::err(code, message);
}

inline std::string errInvalid(std::string_view message) {
    return Result::err("INVALID_PARAMS", message);
}

inline std::string errUnknown(std::string_view action) {
    return Result::err("UNKNOWN_ACTION", action);
}

// ─── Dispatch trampoline ─────────────────────────────────────────────────────
//
// The plugin defines:
//
//     std::string aglet_dispatch_action(std::string_view action,
//                                       std::string_view params_json);
//
// and emits the C ABI exports by placing `AGLET_PLUGIN_EXPORTS` at namespace
// scope (typically near the bottom of the plugin's translation unit).

namespace detail {

inline uint64_t runDispatch(uint32_t ap, uint32_t al, uint32_t pp, uint32_t pl);

} // namespace detail

} // namespace aglet

/// User-provided. Receives the unmarshaled action and params slices, returns
/// the JSON envelope string. The SDK handles ABI exports and result memory.
extern std::string aglet_dispatch_action(std::string_view action,
                                          std::string_view params_json);

namespace aglet::detail {

inline uint64_t runDispatch(uint32_t ap, uint32_t al, uint32_t pp, uint32_t pl) {
    std::string_view action(reinterpret_cast<const char*>(static_cast<uintptr_t>(ap)),
                            static_cast<size_t>(al));
    std::string_view params(reinterpret_cast<const char*>(static_cast<uintptr_t>(pp)),
                            static_cast<size_t>(pl));
    std::string out = aglet_dispatch_action(action, params);
    size_t n = out.size();
    char* buf = static_cast<char*>(std::malloc(n ? n : 1));
    if (n && buf) std::memcpy(buf, out.data(), n);
    return (static_cast<uint64_t>(reinterpret_cast<uintptr_t>(buf)) << 32)
         |  static_cast<uint64_t>(n);
}

} // namespace aglet::detail

/// Emit the three wasm exports (`alloc`, `free`, `dispatch`) that the host
/// runtime expects. Place this at namespace scope in exactly one translation
/// unit of the plugin.
#define AGLET_PLUGIN_EXPORTS                                                      \
    extern "C" {                                                                  \
        __attribute__((export_name("alloc")))                                     \
        uint32_t aglet_sdk_alloc(uint32_t n) {                                    \
            return static_cast<uint32_t>(reinterpret_cast<uintptr_t>(             \
                std::malloc(n ? n : 1)));                                         \
        }                                                                         \
        __attribute__((export_name("free")))                                      \
        void aglet_sdk_free(uint32_t p, uint32_t n) {                             \
            (void)n;                                                              \
            std::free(reinterpret_cast<void*>(static_cast<uintptr_t>(p)));        \
        }                                                                         \
        __attribute__((export_name("dispatch")))                                  \
        uint64_t aglet_sdk_dispatch(uint32_t ap, uint32_t al,                     \
                                    uint32_t pp, uint32_t pl) {                   \
            return ::aglet::detail::runDispatch(ap, al, pp, pl);                  \
        }                                                                         \
    }

#endif // AGLET_PLUGIN_H
