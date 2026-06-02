# Build barcode.wasm —— standalone (无 embind / 无 JS glue) zxing-cpp 包装。
#
# 跟官方 wrappers/wasm/CMakeLists.txt 的差异：
#   - 不 --bind / 不 MODULARIZE / 不 EXPORTED_FUNCTIONS：我们出 STANDALONE_WASM
#     单文件，靠 __attribute__((export_name(...))) 显式导出 alloc/free/dispatch。
#   - 不要 FILESYSTEM / DYNAMIC_EXECUTION：纯 compute，wasm3 无 JS env。
#   - DISABLE_EXCEPTION_CATCHING=0：zxing-cpp 用 throw 做错误传播，得开。
#
# 用法（运行在 aglet-plugins/barcode/ 目录）：
#   ./build.sh
# 它会 cmake configure + build，把 barcode.wasm 拷到 dist/。
#
# 期望 zxing-cpp 源在 ../../zig-pkg/N-V-__8AAL...（由 zig fetch 拉好）。
# 路径走环境变量 ZXING_CPP_ROOT 注入。

cmake_minimum_required(VERSION 3.16)
project(AgletBarcodePlugin)

if(NOT DEFINED ENV{ZXING_CPP_ROOT})
    message(FATAL_ERROR "ZXING_CPP_ROOT env must point at zxing-cpp source root")
endif()
set(ZXING_CPP_ROOT $ENV{ZXING_CPP_ROOT})

include(${ZXING_CPP_ROOT}/zxing.cmake)
zxing_add_package_stb()

# OLD = MultiFormatWriter (没 libzint git submodule 依赖)；wrapper.cpp 用的就是它。
# NEW/ON 会拉 src/libzint/ 这是 zxing-cpp submodule，zig fetch 拉不下来。
set(ZXING_WRITERS "OLD" CACHE STRING "writer impl" FORCE)
option(ZXING_READERS "Build with reader support" ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Release" CACHE STRING "" FORCE)
endif()

# wasm-EH（native wasm exception handling）。zxing-cpp 在 header 里直接 throw，
# -fno-exceptions 编不过；emscripten JS-based exception (默认) 走 invoke_* /
# __cxa_* env imports，无 JS env 的 host 满足不了。所以用 -fwasm-exceptions 出
# native EH。
add_compile_options(-fwasm-exceptions)
add_link_options(-fwasm-exceptions)
# 用 legacy try/catch EH（不是新版 try_table）—— host 跑 WAMR classic 解释器，
# WAMR 稳定支持的是 legacy 提案（WAMR_BUILD_EXCE_HANDLING=1，仅 classic-interp）。
# 新版 try_table 在 WAMR 还在开发中（RFC #3753），故锁 legacy。
add_compile_options(-sWASM_LEGACY_EXCEPTIONS=1)
add_link_options(-sWASM_LEGACY_EXCEPTIONS=1)

add_subdirectory(${ZXING_CPP_ROOT}/core ${CMAKE_BINARY_DIR}/ZXing)

# Standalone wasm：
#   -s STANDALONE_WASM=1     不出 JS glue，输出纯 .wasm
#   -s PURE_WASI=0           不严格 WASI（保留 emscripten 内部，方便 malloc/free）
#   --no-entry               不需要 main()
#   -s ALLOW_MEMORY_GROWTH=1 处理大图编码 / 解码动态扩 mem
#   -s INITIAL_MEMORY=4MB    初始线性内存
set(CMAKE_EXE_LINKER_FLAGS
    "${CMAKE_EXE_LINKER_FLAGS} \
     -s STANDALONE_WASM=1 \
     -s FILESYSTEM=0 \
     -s ALLOW_MEMORY_GROWTH=1 \
     -s INITIAL_MEMORY=4MB \
     -fwasm-exceptions \
     -Wl,--no-entry")
# 注：alloc / free / dispatch 三 export 走 wrapper.cpp 的
# __attribute__((export_name(...)))，linker 不用单独 --export=。

# Aglet plugin SDK (header-only) — sits at ../sdk/c/ in the repo.
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../sdk/c
                 ${CMAKE_BINARY_DIR}/aglet_plugin_sdk_c)

add_executable(barcode src/wrapper.cpp)
target_link_libraries(barcode ZXing::ZXing stb::stb aglet_plugin_sdk_c)
set_target_properties(barcode PROPERTIES SUFFIX ".wasm")
