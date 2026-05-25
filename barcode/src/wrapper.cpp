// barcode plugin — zxing-cpp standalone wasm wrapper.
//
// Built on `aglet_plugin_sdk` (sdk/c/aglet_plugin.h): the SDK owns the
// alloc/free/dispatch wasm exports, JSON parsing, base64 encoding, and
// error envelopes, so this file holds only the two action handlers.
//
// Protocol (JSON in/out):
//   action="encode"
//     params:  {"text":"...", "format":"QRCode", "ecc":-1, "margin":4, "width":256, "height":256}
//     result:  {"ok":true,"dataUrl":"data:image/png;base64,..."}
//   action="decode"
//     params:  {"width":W, "height":H, "pixels_b64":"..."}   // RGBA8888 pixels
//     result:  {"ok":true,"text":"...","format":"QRCode"}
//   error:     {"ok":false,"error":{"code":"...","message":"..."}}

#include <aglet_plugin.h>

#include <exception>
#include <string>
#include <string_view>
#include <vector>

#include "BarcodeFormat.h"
#include "MultiFormatWriter.h"
#include "BitMatrix.h"
#include "CharacterSet.h"
#include "ReadBarcode.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include <stb_image_write.h>

using namespace ZXing;

// ─── action handlers ─────────────────────────────────────────────────────────

static std::string doEncode(const aglet::Params& p) {
    try {
        auto text = p.strOr("text", "");
        auto fmt = p.strOr("format", "QRCode");
        int ecc = static_cast<int>(p.integer("ecc", -1));
        int margin = static_cast<int>(p.integer("margin", 4));
        int w = static_cast<int>(p.integer("width", 0));
        int h = static_cast<int>(p.integer("height", 0));

        if (text.empty()) return aglet::errInvalid("text empty");

        auto bf = BarcodeFormatFromString(fmt);
        if (bf == BarcodeFormat::None)
            return aglet::err("UNSUPPORTED_FORMAT", fmt);

        MultiFormatWriter writer(bf);
        if (margin >= 0) writer.setMargin(margin);
        if (ecc >= 0 && ecc <= 8) writer.setEccLevel(ecc);

        auto bm = ToMatrix<uint8_t>(writer.encode(text, w, h));

        int png_len = 0;
        uint8_t* png = stbi_write_png_to_mem(
            bm.data(), 0, bm.width(), bm.height(), 1, &png_len);
        if (!png || png_len <= 0)
            return aglet::err("ENCODE", "stbi failed");

        std::string b64 = aglet::encodeB64(png, static_cast<size_t>(png_len));
        STBIW_FREE(png);

        // dataUrl is conventionally a single pre-formed URI string, not a
        // separate base64 payload, so build it explicitly.
        std::string data_url = "data:image/png;base64,";
        data_url += b64;
        return aglet::Result::ok().str("dataUrl", data_url);
    } catch (const std::exception& e) {
        return aglet::err("ENCODE", e.what());
    } catch (...) {
        return aglet::err("ENCODE", "unknown");
    }
}

static std::string doDecode(const aglet::Params& p) {
    try {
        int w = static_cast<int>(p.integer("width", 0));
        int h = static_cast<int>(p.integer("height", 0));
        auto pixels = p.bytes("pixels_b64");

        if (w <= 0 || h <= 0 || pixels.empty())
            return aglet::errInvalid("need width/height/pixels_b64");
        if (static_cast<int>(pixels.size()) < w * h * 4)
            return aglet::errInvalid("pixels too short");

        ImageView img(pixels.data(), w, h, ImageFormat::RGBA);
        auto results = ReadBarcodes(img);
        if (results.empty())
            return aglet::err("NOT_FOUND", "no barcode detected");

        const auto& r = results.front();
        return aglet::Result::ok()
            .str("text", r.text())
            .str("format", ToString(r.format()));
    } catch (const std::exception& e) {
        return aglet::err("DECODE", e.what());
    } catch (...) {
        return aglet::err("DECODE", "unknown");
    }
}

// ─── dispatch ────────────────────────────────────────────────────────────────

std::string aglet_dispatch_action(std::string_view action,
                                  std::string_view params_json) {
    aglet::Params p(params_json);
    if (action == "encode") return doEncode(p);
    if (action == "decode") return doDecode(p);
    return aglet::errUnknown(action);
}

AGLET_PLUGIN_EXPORTS
