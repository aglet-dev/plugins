# Build image.wasm —— stb + libwebp standalone (无 embind / 无 JS glue)。
#
# 跟 barcode/CMakeLists.txt 同模式但简化（stb 是 header-only，libwebp 也是
# 纯 C lib 不需要 C++ EH）。-fno-exceptions 关 C++ 异常（wrapper.cpp 没用
# try/catch，stb/libwebp 都是纯 C）。
#
# 用法（在 aglet-plugins/image/）：
#   ./build.sh

cmake_minimum_required(VERSION 3.16)
project(AgletImagePlugin C CXX)

if(NOT DEFINED ENV{LIBWEBP_ROOT})
    message(FATAL_ERROR "LIBWEBP_ROOT env must point at libwebp source root")
endif()
set(LIBWEBP_ROOT $ENV{LIBWEBP_ROOT})

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Release" CACHE STRING "" FORCE)
endif()

# 关掉 libwebp 所有 cli tools / extras / animation utilities，只要库
set(WEBP_BUILD_ANIM_UTILS OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_CWEBP      OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_DWEBP      OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_GIF2WEBP   OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_IMG2WEBP   OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_VWEBP      OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_WEBPINFO   OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_LIBWEBPMUX OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_WEBPMUX    OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_EXTRAS     OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_FUZZTEST   OFF CACHE BOOL "" FORCE)
set(WEBP_USE_THREAD       OFF CACHE BOOL "" FORCE)   # wasm 单线程
set(WEBP_LINK_STATIC      ON  CACHE BOOL "" FORCE)
set(WEBP_BUILD_WEBP_JS    OFF CACHE BOOL "" FORCE)

add_subdirectory(${LIBWEBP_ROOT} ${CMAKE_BINARY_DIR}/libwebp)

add_compile_options(-fno-exceptions)
add_link_options(-fno-exceptions)

set(CMAKE_EXE_LINKER_FLAGS
    "${CMAKE_EXE_LINKER_FLAGS} \
     -s STANDALONE_WASM=1 \
     -s FILESYSTEM=0 \
     -s ALLOW_MEMORY_GROWTH=1 \
     -s INITIAL_MEMORY=16MB \
     -Wl,--no-entry")

# Aglet plugin SDK (header-only) — sits at ../sdk/c/ in the repo.
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../sdk/c
                 ${CMAKE_BINARY_DIR}/aglet_plugin_sdk_c)

add_executable(image src/wrapper.cpp)
target_include_directories(image PRIVATE ${LIBWEBP_ROOT}/src ${LIBWEBP_ROOT})
target_link_libraries(image PRIVATE webp aglet_plugin_sdk_c)
set_target_properties(image PROPERTIES SUFFIX ".wasm")
