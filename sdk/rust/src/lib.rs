//! Aglet wasm plugin SDK (Rust).
//!
//! ABI 跟 sdk/c + sdk/zig 镜像一致：wasm 导出 `alloc(n)->ptr`、`free(ptr,n)`、
//! `dispatch(ap,al,pp,pl)->u64`（结果打包 `(ptr<<32)|len`，指向插件线性内存）。
//! host 把 (action, params_json) 拷进内存调 dispatch，按 packed 取回结果切片。
//!
//! 用法（plugin crate）：
//!     fn handle(action: &str, params_json: &str) -> String { ... }
//!     aglet_plugin_sdk::export_plugin!(handle);
//!
//! wasm32 里指针 == 线性内存字节偏移，所以 host 传来的 u32 直接当指针用。

use std::alloc::{alloc, dealloc, Layout};

/// host 调：分配 n 字节，返回指针（= 线性内存偏移）。align 1，free 时对齐。
pub fn _alloc(n: u32) -> u32 {
    if n == 0 {
        return 0;
    }
    unsafe {
        let layout = Layout::from_size_align_unchecked(n as usize, 1);
        alloc(layout) as u32
    }
}

/// host 调：释放 alloc 出去的内存（含 dispatch 返回的结果缓冲）。
pub fn _free(ptr: u32, n: u32) {
    if ptr == 0 || n == 0 {
        return;
    }
    unsafe {
        let layout = Layout::from_size_align_unchecked(n as usize, 1);
        dealloc(ptr as *mut u8, layout);
    }
}

/// host 调：读 action/params，跑 handler，把结果字符串 alloc 进线性内存，
/// 返回 packed `(ptr<<32)|len`。结果缓冲由 host 之后 free。
pub fn _dispatch(ap: u32, al: u32, pp: u32, pl: u32, f: fn(&str, &str) -> String) -> u64 {
    let action = unsafe {
        std::str::from_utf8_unchecked(std::slice::from_raw_parts(ap as *const u8, al as usize))
    };
    let params = unsafe {
        std::str::from_utf8_unchecked(std::slice::from_raw_parts(pp as *const u8, pl as usize))
    };
    let out = f(action, params);
    let bytes = out.as_bytes();
    let len = bytes.len() as u32;
    let ptr = _alloc(len);
    if ptr != 0 {
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, bytes.len());
        }
    }
    ((ptr as u64) << 32) | (len as u64)
}

/// 在 plugin crate 里生成 alloc/free/dispatch 三个 wasm 导出。
/// 必须在 plugin crate（cdylib）里展开，导出符号才进最终 wasm。
#[macro_export]
macro_rules! export_plugin {
    ($handler:path) => {
        // ABI 导出统一加 `aglet_` 前缀（canonical）。host 查找 `aglet_<name>` 优先、
        // 裸名回退。前缀也彻底避开 wasm-ld 对 `free`/`malloc` 等 libc allocator 名的
        // 特殊处理（裸 `free` 会被吞掉不进导出表）。
        #[export_name = "aglet_alloc"]
        pub extern "C" fn _aglet_alloc(n: u32) -> u32 {
            $crate::_alloc(n)
        }
        #[export_name = "aglet_free"]
        pub extern "C" fn _aglet_free(ptr: u32, n: u32) {
            $crate::_free(ptr, n)
        }
        #[export_name = "aglet_dispatch"]
        pub extern "C" fn _aglet_dispatch(ap: u32, al: u32, pp: u32, pl: u32) -> u64 {
            $crate::_dispatch(ap, al, pp, pl, $handler)
        }
    };
}

// ─── envelope helpers ────────────────────────────────────────────────────────

/// `{"ok":true,"data":<data_json>}` —— `data_json` 是已序列化好的对象（plugin
/// 用 serde_json 之类拼）。
pub fn ok_data(data_json: &str) -> String {
    format!("{{\"ok\":true,\"data\":{}}}", data_json)
}

/// `{"ok":false,"error":{"code":..,"message":..}}`
pub fn err(code: &str, msg: &str) -> String {
    format!(
        "{{\"ok\":false,\"error\":{{\"code\":\"{}\",\"message\":\"{}\"}}}}",
        code,
        json_escape(msg)
    )
}

pub fn err_invalid(msg: &str) -> String {
    err("INVALID_PARAMS", msg)
}

/// 最小 JSON 字符串转义（给 err message / 简单字段用）。
pub fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}
