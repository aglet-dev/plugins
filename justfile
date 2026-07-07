# aglet-plugins 构建入口 —— 单一动词 `just`。
#
# 插件仍走 build.zig(与主仓 aglet 的 bazel 不同:插件是独立小程序/wasm,build.zig 够用)。
# 裸 `zig build` 被主仓的 guard-native-build hook 拦是对的(强制「构建走单一入口」);
# 这里用 recipe 封装,`zig build` 只在 recipe 内部调用。
#
# 用法:
#   just              # 列 recipes
#   just build aicreds                 # 建单个 target step(host)
#   just build aicreds-darwin-x86_64   # 建交叉编 target
#   just all                           # 建全部插件(host + 交叉编)

default:
    @just --list

# 透传到 build.zig 的 step(target 名见 build.zig:各 addStdioNativePlugin / wasm step)。
build *args:
    zig build {{args}}

# 全部插件(所有 target)。
all:
    zig build all
