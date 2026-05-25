//! crypto plugin — pure-zig wasm32-wasi using std.crypto.
//!
//! Built on `aglet_plugin_sdk`: the SDK owns the alloc/free/dispatch wasm
//! exports + JSON marshaling, so this file is just `io_inst` + `csprng` +
//! the action handlers.
//!
//! Actions (JSON in/out, fields are base64 strings):
//!   hash({algo, data_b64}) → {digest_b64}               algo ∈ sha1|sha256|sha512|blake2b
//!   hmac({algo, key_b64, data_b64}) → {mac_b64}         algo ∈ sha1|sha256|sha512
//!   kdf({password, salt_b64, opslimit, memlimit, key_bytes}) → {key_b64}  Argon2id
//!   encrypt({key_b64, plaintext_b64, ad_b64}) → {ciphertext_b64, nonce_b64}  XChaCha20-Poly1305
//!   decrypt({key_b64, ciphertext_b64, nonce_b64, ad_b64}) → {plaintext_b64}
//!   keypair() → {pub_b64 (32B), sec_b64 (64B)}          Ed25519
//!   sign({sec_b64, data_b64}) → {sig_b64}
//!   verify({pub_b64, data_b64, sig_b64}) → {ok: bool}
//!   random({n}) → {bytes_b64}                           CSPRNG (getrandom via WASI)

const std = @import("std");
const crypto = std.crypto;
const sdk = @import("aglet_plugin_sdk");

// ─── plugin-local: io + CSPRNG ──────────────────────────────────────────────

/// Single-threaded std.Io. argon2 KDF and Ed25519 keygen both require a
/// std.Io argument; wasm has no threads so single-threaded is sufficient.
var io_inst: std.Io.Threaded = .init_single_threaded;
fn io() std.Io {
    return io_inst.io();
}

/// WASI CSPRNG. The host runtime maps `random_get` to the OS RNG
/// (getrandom on Linux, SecRandomCopyBytes on Apple, etc.) inside its sandbox.
fn csprng(buf: []u8) void {
    _ = std.os.wasi.random_get(buf.ptr, buf.len);
}

// ─── wasm exports (alloc/free + dispatch) ───────────────────────────────────

comptime { sdk.exportRuntime(); }

export fn dispatch(ap: u32, al: u32, pp: u32, pl: u32) callconv(.c) u64 {
    return sdk.runDispatch(Handlers, ap, al, pp, pl);
}

// ─── action handlers ────────────────────────────────────────────────────────

const Handlers = struct {
    pub fn hash(p: *sdk.Params) anyerror![]const u8 {
        const algo = p.str("algo") orelse "blake2b";
        const data = try p.bytes("data_b64");
        if (std.mem.eql(u8, algo, "sha1")) {
            var out: [crypto.hash.Sha1.digest_length]u8 = undefined;
            crypto.hash.Sha1.hash(data, &out, .{});
            return sdk.okBytes(p.arena, "digest_b64", &out);
        }
        if (std.mem.eql(u8, algo, "sha256")) {
            var out: [crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            crypto.hash.sha2.Sha256.hash(data, &out, .{});
            return sdk.okBytes(p.arena, "digest_b64", &out);
        }
        if (std.mem.eql(u8, algo, "sha512")) {
            var out: [crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
            crypto.hash.sha2.Sha512.hash(data, &out, .{});
            return sdk.okBytes(p.arena, "digest_b64", &out);
        }
        if (std.mem.eql(u8, algo, "blake2b")) {
            var out: [crypto.hash.blake2.Blake2b256.digest_length]u8 = undefined;
            crypto.hash.blake2.Blake2b256.hash(data, &out, .{});
            return sdk.okBytes(p.arena, "digest_b64", &out);
        }
        return sdk.errInvalid(p.arena, "algo must be sha1 / sha256 / sha512 / blake2b");
    }

    pub fn hmac(p: *sdk.Params) anyerror![]const u8 {
        const algo = p.str("algo") orelse "sha256";
        const key = try p.bytes("key_b64");
        const data = try p.bytes("data_b64");
        if (std.mem.eql(u8, algo, "sha1")) {
            const H = crypto.auth.hmac.HmacSha1;
            var out: [H.mac_length]u8 = undefined;
            H.create(&out, data, key);
            return sdk.okBytes(p.arena, "mac_b64", &out);
        }
        if (std.mem.eql(u8, algo, "sha256")) {
            const H = crypto.auth.hmac.sha2.HmacSha256;
            var out: [H.mac_length]u8 = undefined;
            H.create(&out, data, key);
            return sdk.okBytes(p.arena, "mac_b64", &out);
        }
        if (std.mem.eql(u8, algo, "sha512")) {
            const H = crypto.auth.hmac.sha2.HmacSha512;
            var out: [H.mac_length]u8 = undefined;
            H.create(&out, data, key);
            return sdk.okBytes(p.arena, "mac_b64", &out);
        }
        return sdk.errInvalid(p.arena, "algo must be sha1 / sha256 / sha512");
    }

    pub fn kdf(p: *sdk.Params) anyerror![]const u8 {
        const password = p.str("password") orelse "";
        const salt = try p.bytes("salt_b64");
        const opslimit = p.int("opslimit", 3);
        const memlimit_kb = p.int("memlimit", 64 * 1024); // 64 MB
        const key_bytes = p.int("key_bytes", 32);
        if (salt.len < 8) return sdk.errInvalid(p.arena, "salt must be ≥ 8 bytes");
        if (key_bytes < 16 or key_bytes > 1024) return sdk.errInvalid(p.arena, "key_bytes out of range (16..1024)");
        const out = try p.arena.alloc(u8, @intCast(key_bytes));
        const params_arg = crypto.pwhash.argon2.Params{
            .t = @intCast(opslimit),
            .m = @intCast(memlimit_kb),
            .p = 1,
        };
        crypto.pwhash.argon2.kdf(p.arena, out, password, salt, params_arg, .argon2id, io()) catch
            return sdk.err(p.arena, "KDF_FAILED", "argon2id failed (likely out of memory)");
        return sdk.okBytes(p.arena, "key_b64", out);
    }

    pub fn encrypt(p: *sdk.Params) anyerror![]const u8 {
        const key = try p.bytes("key_b64");
        const pt = try p.bytes("plaintext_b64");
        const ad = (try p.optBytes("ad_b64")) orelse &[_]u8{};
        if (key.len != 32) return sdk.errInvalid(p.arena, "key must be 32 bytes");

        const AEAD = crypto.aead.chacha_poly.XChaCha20Poly1305;
        var nonce: [AEAD.nonce_length]u8 = undefined;
        csprng(&nonce);
        const ct = try p.arena.alloc(u8, pt.len);
        var tag: [AEAD.tag_length]u8 = undefined;
        var key_arr: [AEAD.key_length]u8 = undefined;
        @memcpy(&key_arr, key);
        AEAD.encrypt(ct, &tag, pt, ad, nonce, key_arr);
        // libsodium-style: ciphertext || tag concatenated
        const full = try p.arena.alloc(u8, ct.len + tag.len);
        @memcpy(full[0..ct.len], ct);
        @memcpy(full[ct.len..], &tag);
        return sdk.ok(p.arena, .{
            .ciphertext_b64 = try sdk.encodeB64(p.arena, full),
            .nonce_b64 = try sdk.encodeB64(p.arena, &nonce),
        });
    }

    pub fn decrypt(p: *sdk.Params) anyerror![]const u8 {
        const key = try p.bytes("key_b64");
        const ct_with_tag = try p.bytes("ciphertext_b64");
        const nonce_in = try p.bytes("nonce_b64");
        const ad = (try p.optBytes("ad_b64")) orelse &[_]u8{};
        const AEAD = crypto.aead.chacha_poly.XChaCha20Poly1305;
        if (key.len != AEAD.key_length) return sdk.errInvalid(p.arena, "key must be 32 bytes");
        if (nonce_in.len != AEAD.nonce_length) return sdk.errInvalid(p.arena, "nonce must be 24 bytes");
        if (ct_with_tag.len < AEAD.tag_length) return sdk.errInvalid(p.arena, "ciphertext too short");

        const ct_len = ct_with_tag.len - AEAD.tag_length;
        const ct = ct_with_tag[0..ct_len];
        var tag: [AEAD.tag_length]u8 = undefined;
        @memcpy(&tag, ct_with_tag[ct_len..]);
        var key_arr: [AEAD.key_length]u8 = undefined;
        @memcpy(&key_arr, key);
        var nonce_arr: [AEAD.nonce_length]u8 = undefined;
        @memcpy(&nonce_arr, nonce_in);
        const pt = try p.arena.alloc(u8, ct_len);
        AEAD.decrypt(pt, ct, tag, ad, nonce_arr, key_arr) catch
            return sdk.err(p.arena, "DECRYPT_FAILED", "auth tag mismatch or corrupt");
        return sdk.okBytes(p.arena, "plaintext_b64", pt);
    }

    pub fn keypair(p: *sdk.Params) anyerror![]const u8 {
        const Ed = crypto.sign.Ed25519;
        const kp = Ed.KeyPair.generate(io());
        const pub_b = kp.public_key.toBytes();
        const sec_b = kp.secret_key.toBytes();
        return sdk.ok(p.arena, .{
            .pub_b64 = try sdk.encodeB64(p.arena, &pub_b),
            .sec_b64 = try sdk.encodeB64(p.arena, &sec_b),
        });
    }

    pub fn sign(p: *sdk.Params) anyerror![]const u8 {
        const sec = try p.bytes("sec_b64");
        const data = try p.bytes("data_b64");
        const Ed = crypto.sign.Ed25519;
        if (sec.len != Ed.SecretKey.encoded_length) return sdk.errInvalid(p.arena, "sec_b64 must be 64 bytes");
        var sec_arr: [Ed.SecretKey.encoded_length]u8 = undefined;
        @memcpy(&sec_arr, sec);
        const sk = Ed.SecretKey.fromBytes(sec_arr) catch
            return sdk.errInvalid(p.arena, "invalid secret key");
        const kp = Ed.KeyPair.fromSecretKey(sk) catch
            return sdk.errInvalid(p.arena, "invalid secret key");
        const sig = kp.sign(data, null) catch
            return sdk.err(p.arena, "SIGN_FAILED", "sign failed");
        const sig_b = sig.toBytes();
        return sdk.okBytes(p.arena, "sig_b64", &sig_b);
    }

    pub fn verify(p: *sdk.Params) anyerror![]const u8 {
        const pub_b = try p.bytes("pub_b64");
        const data = try p.bytes("data_b64");
        const sig_b = try p.bytes("sig_b64");
        const Ed = crypto.sign.Ed25519;
        if (pub_b.len != Ed.PublicKey.encoded_length) return sdk.errInvalid(p.arena, "pub_b64 must be 32 bytes");
        if (sig_b.len != Ed.Signature.encoded_length) return sdk.errInvalid(p.arena, "sig_b64 must be 64 bytes");

        var pub_arr: [Ed.PublicKey.encoded_length]u8 = undefined;
        @memcpy(&pub_arr, pub_b);
        var sig_arr: [Ed.Signature.encoded_length]u8 = undefined;
        @memcpy(&sig_arr, sig_b);
        const pk = Ed.PublicKey.fromBytes(pub_arr) catch
            return sdk.okBool(p.arena, "ok", false);
        const sig = Ed.Signature.fromBytes(sig_arr);
        sig.verify(data, pk) catch
            return sdk.okBool(p.arena, "ok", false);
        return sdk.okBool(p.arena, "ok", true);
    }

    pub fn random(p: *sdk.Params) anyerror![]const u8 {
        const n = p.int("n", 0);
        if (n <= 0 or n > 1024 * 1024) return sdk.errInvalid(p.arena, "n must be in (0, 1MB]");
        const buf = try p.arena.alloc(u8, @intCast(n));
        csprng(buf);
        return sdk.okBytes(p.arena, "bytes_b64", buf);
    }
};
