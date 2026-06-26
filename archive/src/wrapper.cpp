// archive plugin — libarchive standalone wasm wrapper.
//
// Protocol (JSON in/out):
//   list({input_b64})               → {entries: [{path, size, is_dir, mtime}, ...]}
//   extract({input_b64, path})      → {bytes_b64}
//   create({format, entries: [{path, bytes_b64}, ...]})
//                                    → {output_b64}
//     format ∈ {"zip", "tar", "tar.gz"}
//
// Supported read formats: zip / tar / tar.{gz,bz2} / rar (4 + 5) / ar / cpio /
// iso / mtree / 7z (without lzma; will fail). libarchive's
// `archive_read_support_*_all` enables every format / filter compiled in.
//
// Built on `aglet_plugin_sdk` (sdk/c/aglet_plugin.h): the SDK owns the
// alloc/free/dispatch wasm exports, JSON parsing, base64 encoding, and
// error envelopes.

#include <aglet_plugin.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

#include "archive.h"
#include "archive_entry.h"

// ─── action handlers ────────────────────────────────────────────────────────

static std::string doList(const aglet::Params& p) {
    auto bytes = p.bytes("input_b64");
    if (bytes.empty()) return aglet::errInvalid("input_b64 required (non-empty)");

    struct archive* a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);

    int r = archive_read_open_memory(a, bytes.data(), bytes.size());
    if (r != ARCHIVE_OK) {
        const char* msg = archive_error_string(a);
        std::string err_msg = msg ? msg : "open failed";
        archive_read_free(a);
        return aglet::err("OPEN_FAILED", err_msg);
    }

    // Build the `entries` array as a JSON fragment, then attach it to the
    // Result builder via `raw()`.
    std::string entries = "[";
    bool first = true;
    struct archive_entry* entry;
    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
        if (!first) entries += ",";
        first = false;

        const char* path = archive_entry_pathname(entry);
        int64_t size = archive_entry_size(entry);
        bool is_dir = archive_entry_filetype(entry) == AE_IFDIR;
        int64_t mtime = archive_entry_mtime(entry);

        char tail[128];
        std::snprintf(tail, sizeof(tail),
            ",\"size\":%lld,\"is_dir\":%s,\"mtime\":%lld}",
            static_cast<long long>(size),
            is_dir ? "true" : "false",
            static_cast<long long>(mtime));

        entries += "{\"path\":\"";
        entries += aglet::jsonEscape(path ? path : "");
        entries += "\"";
        entries += tail;

        archive_read_data_skip(a);
    }
    entries += "]";

    archive_read_free(a);
    return aglet::Result::ok().raw("entries", entries);
}

static std::string doExtract(const aglet::Params& p) {
    auto bytes = p.bytes("input_b64");
    if (bytes.empty()) return aglet::errInvalid("input_b64 required (non-empty)");
    std::string target_path = p.strOr("path", "");
    if (target_path.empty()) return aglet::errInvalid("path required");

    struct archive* a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);

    int r = archive_read_open_memory(a, bytes.data(), bytes.size());
    if (r != ARCHIVE_OK) {
        const char* msg = archive_error_string(a);
        std::string err_msg = msg ? msg : "open failed";
        archive_read_free(a);
        return aglet::err("OPEN_FAILED", err_msg);
    }

    struct archive_entry* entry;
    std::vector<uint8_t> data;
    bool found = false;
    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
        const char* path = archive_entry_pathname(entry);
        if (path && target_path == path) {
            found = true;
            int64_t size = archive_entry_size(entry);
            if (size > 0) data.reserve(static_cast<size_t>(size));
            const void* buf;
            size_t len;
            la_int64_t offset;
            while (archive_read_data_block(a, &buf, &len, &offset) == ARCHIVE_OK) {
                if (offset > static_cast<la_int64_t>(data.size()))
                    data.resize(static_cast<size_t>(offset));
                data.insert(data.end(),
                            static_cast<const uint8_t*>(buf),
                            static_cast<const uint8_t*>(buf) + len);
            }
            break;
        }
        archive_read_data_skip(a);
    }
    archive_read_free(a);

    if (!found) return aglet::err("NOT_FOUND", "path not in archive: " + target_path);
    return aglet::Result::ok().bytes("bytes_b64", data);
}

// libarchive uses an open/write/close callback model for streaming output.
struct WriteCtx { std::vector<uint8_t> out; };

static la_ssize_t writeCb(struct archive*, void* ud, const void* buf, size_t n) {
    auto* w = static_cast<WriteCtx*>(ud);
    w->out.insert(w->out.end(),
                  static_cast<const uint8_t*>(buf),
                  static_cast<const uint8_t*>(buf) + n);
    return static_cast<la_ssize_t>(n);
}

/// Split an array-of-objects substring at top-level commas, returning each
/// `{...}` element as a substring suitable for `aglet::Params`.
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

static std::string doCreate(const aglet::Params& p) {
    std::string format = p.strOr("format", "tar.gz");
    auto entries_range = p.findArray("entries");
    if (!entries_range) return aglet::errInvalid("entries array required");

    struct archive* a = archive_write_new();
    if (format == "zip") {
        archive_write_set_format_zip(a);
    } else if (format == "tar") {
        archive_write_set_format_pax_restricted(a);
    } else if (format == "tar.gz") {
        archive_write_set_format_pax_restricted(a);
        archive_write_add_filter_gzip(a);
    } else {
        archive_write_free(a);
        return aglet::errInvalid("format must be zip / tar / tar.gz");
    }

    WriteCtx ctx;
    archive_write_open(a, &ctx, nullptr, writeCb, nullptr);

    auto [start, end] = *entries_range;
    for (auto entry_json : splitObjArray(p.raw(), start, end)) {
        aglet::Params item(entry_json);
        std::string path = item.strOr("path", "");
        if (path.empty()) continue;
        auto data = item.bytes("bytes_b64");

        struct archive_entry* archive_entry = archive_entry_new();
        archive_entry_set_pathname(archive_entry, path.c_str());
        archive_entry_set_size(archive_entry, static_cast<la_int64_t>(data.size()));
        archive_entry_set_filetype(archive_entry, AE_IFREG);
        archive_entry_set_perm(archive_entry, 0644);
        archive_write_header(a, archive_entry);
        if (!data.empty()) {
            archive_write_data(a, data.data(), data.size());
        }
        archive_entry_free(archive_entry);
    }

    archive_write_close(a);
    archive_write_free(a);

    return aglet::Result::ok().bytes("output_b64", ctx.out);
}

// ─── dispatch ────────────────────────────────────────────────────────────────

std::string aglet_dispatch_action(std::string_view action,
                                  std::string_view params_json) {
    aglet::Params p(params_json);
    if (action == "list")    return doList(p);
    if (action == "extract") return doExtract(p);
    if (action == "create")  return doCreate(p);
    return aglet::errUnknown(std::string("archive.") + std::string(action));
}

AGLET_PLUGIN_EXPORTS
