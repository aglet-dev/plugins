// image plugin v2 — primitives + pipeline (decode / encode / process / metadata).
//
// Design: expose primitives so callers can compose. `process` chains
// decode → ops[] → encode in a single wasm call to skip intermediate base64
// marshaling; the other actions remain available for ad-hoc use.
//
// Protocol (JSON in/out):
//   metadata({input_b64}) → {width, height, channels, format}
//   decode({input_b64})   → {pixels_b64, width, height, channels, src_format}
//   encode({pixels_b64, width, height, format, quality?, lossless?})
//                          → {output_b64, format}
//   process({input_b64, ops?:[...], output_format?, quality?, lossless?})
//                          → {output_b64, width, height, format}
//     ops kinds:
//       {kind:"resize", w, h}
//       {kind:"crop",   x, y, w, h}
//       {kind:"rotate", degrees}        // 90 / 180 / 270 only
//       {kind:"flip",   axis:"x"|"y"}
//
// Decode normalizes to RGBA8888; transforms operate on the RGBA buffer; encode
// drops alpha for formats that lack it (JPEG). stb_image_resize2 handles the
// resize; rotate/flip are hand-rolled.
//
// Built on `aglet_plugin_sdk` (sdk/c/aglet_plugin.h): the SDK owns the
// alloc/free/dispatch wasm exports, JSON parsing, base64 encoding, and
// error envelopes.

#include <aglet_plugin.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_NO_THREAD_LOCALS
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize2.h"

#include "webp/encode.h"
#include "webp/decode.h"

// ─── helpers ────────────────────────────────────────────────────────────────

static void stbWriteCb(void* ctx, void* data, int size) {
    auto* v = static_cast<std::vector<uint8_t>*>(ctx);
    v->insert(v->end(), static_cast<uint8_t*>(data),
                        static_cast<uint8_t*>(data) + size);
}

static const char* sniffFormat(const uint8_t* p, size_t n) {
    if (n >= 8 && p[0] == 0x89 && p[1] == 'P' && p[2] == 'N' && p[3] == 'G') return "png";
    if (n >= 3 && p[0] == 0xFF && p[1] == 0xD8 && p[2] == 0xFF) return "jpeg";
    if (n >= 12 && p[0] == 'R' && p[1] == 'I' && p[2] == 'F' && p[3] == 'F'
                && p[8] == 'W' && p[9] == 'E' && p[10] == 'B' && p[11] == 'P') return "webp";
    if (n >= 2 && p[0] == 'B' && p[1] == 'M') return "bmp";
    if (n >= 6 && p[0] == 'G' && p[1] == 'I' && p[2] == 'F') return "gif";
    return "unknown";
}

/// Split an array-of-objects substring at top-level commas. The SDK locates
/// the [start, end) span via `Params::findArray`; this scans inside it and
/// returns each `{...}` object as a substring suitable for `aglet::Params`.
static std::vector<std::string_view> splitObjArray(std::string_view src, size_t a, size_t b) {
    std::vector<std::string_view> out;
    size_t i = a;
    while (i < b) {
        while (i < b && (src[i] == ' ' || src[i] == ',' || src[i] == '\n' || src[i] == '\t')) i++;
        if (i >= b || src[i] != '{') break;
        int depth = 1;
        size_t start = i;
        i++;
        while (i < b && depth > 0) {
            char c = src[i];
            if (c == '{') depth++;
            else if (c == '}') depth--;
            else if (c == '"') {
                i++;
                while (i < b && src[i] != '"') {
                    if (src[i] == '\\' && i + 1 < b) i++;
                    i++;
                }
            }
            i++;
        }
        out.emplace_back(src.data() + start, i - start);
    }
    return out;
}

// ─── decode / encode ────────────────────────────────────────────────────────

struct Pixels {
    std::vector<uint8_t> rgba;
    int w = 0;
    int h = 0;
    const char* src_format = "unknown";  // pointer into sniffFormat() static strings
};

static bool decodeBytes(const std::vector<uint8_t>& bytes, Pixels& out) {
    out.src_format = sniffFormat(bytes.data(), bytes.size());

    if (std::strcmp(out.src_format, "webp") == 0) {
        int w = 0, h = 0;
        uint8_t* p = WebPDecodeRGBA(bytes.data(), bytes.size(), &w, &h);
        if (!p) return false;
        out.rgba.assign(p, p + static_cast<size_t>(w) * h * 4);
        WebPFree(p);
        out.w = w;
        out.h = h;
        return true;
    }

    int w = 0, h = 0, ch = 0;
    uint8_t* p = stbi_load_from_memory(bytes.data(), static_cast<int>(bytes.size()),
                                       &w, &h, &ch, 4);
    if (!p) return false;
    out.rgba.assign(p, p + static_cast<size_t>(w) * h * 4);
    stbi_image_free(p);
    out.w = w;
    out.h = h;
    return true;
}

static bool encodePixels(const std::vector<uint8_t>& rgba, int w, int h,
                         std::string& format, int quality, bool lossless,
                         std::vector<uint8_t>& out) {
    if (format == "jpg") format = "jpeg";

    if (format == "png") {
        return stbi_write_png_to_func(stbWriteCb, &out, w, h, 4, rgba.data(), w * 4);
    }
    if (format == "jpeg") {
        // JPEG has no alpha — flatten RGBA → RGB.
        std::vector<uint8_t> rgb(static_cast<size_t>(w) * h * 3);
        for (int i = 0; i < w * h; i++) {
            rgb[i * 3 + 0] = rgba[i * 4 + 0];
            rgb[i * 3 + 1] = rgba[i * 4 + 1];
            rgb[i * 3 + 2] = rgba[i * 4 + 2];
        }
        int q = (quality > 0 && quality <= 100) ? quality : 85;
        return stbi_write_jpg_to_func(stbWriteCb, &out, w, h, 3, rgb.data(), q);
    }
    if (format == "bmp") {
        return stbi_write_bmp_to_func(stbWriteCb, &out, w, h, 4, rgba.data());
    }
    if (format == "webp") {
        uint8_t* webp_out = nullptr;
        size_t webp_len = 0;
        if (lossless) {
            webp_len = WebPEncodeLosslessRGBA(rgba.data(), w, h, w * 4, &webp_out);
        } else {
            float q = (quality > 0 && quality <= 100) ? static_cast<float>(quality) : 85.0f;
            webp_len = WebPEncodeRGBA(rgba.data(), w, h, w * 4, q, &webp_out);
        }
        if (webp_len == 0 || !webp_out) return false;
        out.assign(webp_out, webp_out + webp_len);
        WebPFree(webp_out);
        return true;
    }
    return false;
}

// ─── transforms ─────────────────────────────────────────────────────────────

static bool opResize(Pixels& p, int new_w, int new_h) {
    if (new_w <= 0 || new_h <= 0) return false;
    std::vector<uint8_t> dst(static_cast<size_t>(new_w) * new_h * 4);
    if (!stbir_resize_uint8_srgb(p.rgba.data(), p.w, p.h, p.w * 4,
                                  dst.data(), new_w, new_h, new_w * 4,
                                  STBIR_RGBA)) return false;
    p.rgba = std::move(dst);
    p.w = new_w;
    p.h = new_h;
    return true;
}

static bool opCrop(Pixels& p, int x, int y, int cw, int ch) {
    if (x < 0 || y < 0 || cw <= 0 || ch <= 0) return false;
    if (x + cw > p.w || y + ch > p.h) return false;
    std::vector<uint8_t> dst(static_cast<size_t>(cw) * ch * 4);
    for (int j = 0; j < ch; j++) {
        std::memcpy(dst.data() + static_cast<size_t>(j) * cw * 4,
                    p.rgba.data() + static_cast<size_t>(y + j) * p.w * 4
                                 + static_cast<size_t>(x) * 4,
                    static_cast<size_t>(cw) * 4);
    }
    p.rgba = std::move(dst);
    p.w = cw;
    p.h = ch;
    return true;
}

static bool opRotate(Pixels& p, int deg) {
    deg = ((deg % 360) + 360) % 360;
    if (deg == 0) return true;
    int w = p.w, h = p.h;
    std::vector<uint8_t> dst(p.rgba.size());
    if (deg == 180) {
        for (int j = 0; j < h; j++) for (int i = 0; i < w; i++) {
            const uint8_t* s = &p.rgba[(j * w + i) * 4];
            uint8_t* d = &dst[((h - 1 - j) * w + (w - 1 - i)) * 4];
            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3];
        }
        p.rgba = std::move(dst);
        return true;
    }
    if (deg == 90 || deg == 270) {
        for (int j = 0; j < h; j++) for (int i = 0; i < w; i++) {
            const uint8_t* s = &p.rgba[(j * w + i) * 4];
            int ni = (deg == 90) ? (h - 1 - j) : j;
            int nj = (deg == 90) ? i           : (w - 1 - i);
            uint8_t* d = &dst[(nj * h + ni) * 4];
            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3];
        }
        p.rgba = std::move(dst);
        std::swap(p.w, p.h);
        return true;
    }
    return false;  // unreachable: 0/90/180/270 covered above
}

static bool opFlip(Pixels& p, std::string_view axis) {
    int w = p.w, h = p.h;
    if (axis == "x") {  // horizontal flip = mirror along y axis
        for (int j = 0; j < h; j++) {
            uint8_t* row = &p.rgba[static_cast<size_t>(j) * w * 4];
            for (int i = 0; i < w / 2; i++) {
                uint8_t* a = row + i * 4;
                uint8_t* b = row + (w - 1 - i) * 4;
                std::swap(a[0], b[0]); std::swap(a[1], b[1]);
                std::swap(a[2], b[2]); std::swap(a[3], b[3]);
            }
        }
        return true;
    }
    if (axis == "y") {  // vertical flip = mirror along x axis
        for (int j = 0; j < h / 2; j++) {
            uint8_t* a = &p.rgba[static_cast<size_t>(j) * w * 4];
            uint8_t* b = &p.rgba[static_cast<size_t>(h - 1 - j) * w * 4];
            for (int i = 0; i < w * 4; i++) std::swap(a[i], b[i]);
        }
        return true;
    }
    return false;
}

static bool applyOp(Pixels& p, std::string_view op_json, std::string& err_msg) {
    aglet::Params op(op_json);
    std::string kind = op.strOr("kind", "");
    if (kind == "resize") {
        int w = static_cast<int>(op.integer("w", 0));
        int h = static_cast<int>(op.integer("h", 0));
        if (!opResize(p, w, h)) { err_msg = "resize: bad dimensions"; return false; }
        return true;
    }
    if (kind == "crop") {
        int x = static_cast<int>(op.integer("x", 0));
        int y = static_cast<int>(op.integer("y", 0));
        int w = static_cast<int>(op.integer("w", 0));
        int h = static_cast<int>(op.integer("h", 0));
        if (!opCrop(p, x, y, w, h)) { err_msg = "crop: out of bounds"; return false; }
        return true;
    }
    if (kind == "rotate") {
        int deg = static_cast<int>(op.integer("degrees", 0));
        if (!opRotate(p, deg)) { err_msg = "rotate: only 90/180/270 supported"; return false; }
        return true;
    }
    if (kind == "flip") {
        std::string axis = op.strOr("axis", "");
        if (!opFlip(p, axis)) { err_msg = "flip: axis must be 'x' or 'y'"; return false; }
        return true;
    }
    err_msg = "unknown op kind: " + kind;
    return false;
}

// ─── action handlers ────────────────────────────────────────────────────────

static std::string doMetadata(const aglet::Params& p) {
    auto bytes = p.bytes("input_b64");
    if (bytes.empty()) return aglet::errInvalid("need input_b64 (non-empty)");

    const char* fmt = sniffFormat(bytes.data(), bytes.size());
    int w = 0, h = 0, ch = 0;
    if (std::strcmp(fmt, "webp") == 0) {
        if (!WebPGetInfo(bytes.data(), bytes.size(), &w, &h))
            return aglet::err("METADATA", "WebPGetInfo failed");
        ch = 4;
    } else {
        if (!stbi_info_from_memory(bytes.data(), static_cast<int>(bytes.size()), &w, &h, &ch))
            return aglet::err("METADATA", "stbi_info failed");
    }
    return aglet::Result::ok()
        .integer("width", w)
        .integer("height", h)
        .integer("channels", ch)
        .str("format", fmt);
}

static std::string doDecode(const aglet::Params& p) {
    auto bytes = p.bytes("input_b64");
    if (bytes.empty()) return aglet::errInvalid("need input_b64 (non-empty)");

    Pixels pixels;
    if (!decodeBytes(bytes, pixels))
        return aglet::err("DECODE", "unsupported or corrupt input");

    return aglet::Result::ok()
        .bytes("pixels_b64", pixels.rgba)
        .integer("width", pixels.w)
        .integer("height", pixels.h)
        .integer("channels", 4)
        .str("src_format", pixels.src_format);
}

static std::string doEncode(const aglet::Params& p) {
    auto px = p.bytes("pixels_b64");
    int w = static_cast<int>(p.integer("width", 0));
    int h = static_cast<int>(p.integer("height", 0));
    std::string fmt = p.strOr("format", "");
    int quality = static_cast<int>(p.integer("quality", 85));
    bool lossless = p.boolean("lossless").value_or(false);

    if (px.empty() || w <= 0 || h <= 0 || fmt.empty())
        return aglet::errInvalid("need pixels_b64 + width + height + format");
    if (static_cast<int>(px.size()) < w * h * 4)
        return aglet::errInvalid("pixels too short");

    std::vector<uint8_t> out;
    if (!encodePixels(px, w, h, fmt, quality, lossless, out))
        return aglet::err("ENCODE", "unsupported output format: " + fmt);

    return aglet::Result::ok()
        .bytes("output_b64", out)
        .str("format", fmt);
}

static std::string doProcess(const aglet::Params& p) {
    auto bytes = p.bytes("input_b64");
    if (bytes.empty()) return aglet::errInvalid("need input_b64 (non-empty)");

    Pixels pixels;
    if (!decodeBytes(bytes, pixels))
        return aglet::err("DECODE", "unsupported or corrupt input");

    // Apply ops array (optional).
    if (auto range = p.findArray("ops")) {
        auto [a, b] = *range;
        for (auto op_json : splitObjArray(p.raw(), a, b)) {
            std::string err_msg;
            if (!applyOp(pixels, op_json, err_msg))
                return aglet::err("INVALID_OP", err_msg);
        }
    }

    // output_format defaults to the source format (pure-transform case).
    std::string fmt = p.strOr("output_format", pixels.src_format);
    int quality = static_cast<int>(p.integer("quality", 85));
    bool lossless = p.boolean("lossless").value_or(false);

    std::vector<uint8_t> out;
    if (!encodePixels(pixels.rgba, pixels.w, pixels.h, fmt, quality, lossless, out))
        return aglet::err("ENCODE", "unsupported output format: " + fmt);

    return aglet::Result::ok()
        .bytes("output_b64", out)
        .integer("width", pixels.w)
        .integer("height", pixels.h)
        .str("format", fmt);
}

// ─── dispatch ────────────────────────────────────────────────────────────────

std::string aglet_dispatch_action(std::string_view action,
                                  std::string_view params_json) {
    aglet::Params p(params_json);
    if (action == "metadata") return doMetadata(p);
    if (action == "decode")   return doDecode(p);
    if (action == "encode")   return doEncode(p);
    if (action == "process")  return doProcess(p);
    return aglet::errUnknown(std::string("image.") + std::string(action));
}

AGLET_PLUGIN_EXPORTS
