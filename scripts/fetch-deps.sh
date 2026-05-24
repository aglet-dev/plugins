#!/usr/bin/env bash
# Fetch upstream C/C++ deps into vendor/zig-pkg/<hash>/，让 build.sh 不依赖 sibling
# aglet checkout 也能跑（CI / fresh clone）。
#
# Hash 跟 aglet/build.zig.zon 对齐；URL 是上游 release tarball。
# 跑完后 build.sh 第三优先级路径 `./vendor/zig-pkg/<hash>` 拿到内容。
#
# 用法：
#   ./scripts/fetch-deps.sh           # 全拉
#   ./scripts/fetch-deps.sh zxing     # 只拉 zxing
#   ./scripts/fetch-deps.sh webp      # 只拉 libwebp
#
# 不用 bash 4 associative array —— macOS 默认 bash 3.2 兼容。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/zig-pkg"
mkdir -p "$VENDOR"

# hash 跟 aglet/build.zig.zon dependencies.* 完全一致。
ZXING_HASH="N-V-__8AALGrMwDZ4Ry7UDuLwgq1EZDZbRbLN75PkGihtghn"
ZXING_URL="https://github.com/zxing-cpp/zxing-cpp/archive/refs/tags/v3.0.2.tar.gz"

WEBP_HASH="N-V-__8AAGkrewARcKiSyLfJKsaW0ZoqHh4hzi4mTGwekxjk"
WEBP_URL="https://github.com/webmproject/libwebp/archive/refs/tags/v1.6.0.tar.gz"

fetch_one() {
  local name="$1"
  local hash="$2"
  local url="$3"
  local target="$VENDOR/$hash"

  if [ -d "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
    echo "[$name] already vendored at $target"
    return 0
  fi

  echo "[$name] fetching $url → $target"
  mkdir -p "$target"
  curl -fsSL "$url" | tar -xz --strip-components=1 -C "$target"
  echo "[$name] ✓ ($(find "$target" -type f | wc -l | tr -d ' ') files)"
}

dispatch() {
  case "$1" in
    zxing) fetch_one zxing "$ZXING_HASH" "$ZXING_URL" ;;
    webp)  fetch_one webp  "$WEBP_HASH"  "$WEBP_URL" ;;
    *) echo "unknown dep: $1 (known: zxing webp)" >&2; exit 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  dispatch zxing
  dispatch webp
else
  for name in "$@"; do
    dispatch "$name"
  done
fi
