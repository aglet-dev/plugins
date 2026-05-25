# Build archive.wasm —— libarchive standalone via emscripten.
# Read: zip / tar / tar.{gz,bz2} / rar (4 + 5) / ar / cpio / iso
# Write: zip / tar / tar.gz

cmake_minimum_required(VERSION 3.16)
project(AgletArchivePlugin C CXX)

if(NOT DEFINED ENV{LIBARCHIVE_ROOT})
    message(FATAL_ERROR "LIBARCHIVE_ROOT env must point at libarchive source root")
endif()
set(LIBARCHIVE_ROOT $ENV{LIBARCHIVE_ROOT})

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Release" CACHE STRING "" FORCE)
endif()

# zlib + bzip2 via emscripten ports — no external vendoring needed.
add_compile_options("SHELL:-sUSE_ZLIB=1" "SHELL:-sUSE_BZIP2=1")
add_link_options("SHELL:-sUSE_ZLIB=1" "SHELL:-sUSE_BZIP2=1")

# Tell libarchive's CMake about zlib/bz2 (emscripten ports satisfy these)
set(ZLIB_INCLUDE_DIR  "/__skip__"  CACHE PATH "" FORCE)
set(ZLIB_LIBRARY      "z"          CACHE STRING "" FORCE)
set(BZIP2_INCLUDE_DIR "/__skip__"  CACHE PATH "" FORCE)
set(BZIP2_LIBRARIES   "bz2"        CACHE STRING "" FORCE)

# libarchive options — strip everything we don't need for wasm pure-compute.
set(BUILD_SHARED_LIBS    OFF CACHE BOOL "" FORCE)
set(ENABLE_TEST          OFF CACHE BOOL "" FORCE)
set(ENABLE_TAR           OFF CACHE BOOL "" FORCE)
set(ENABLE_CPIO          OFF CACHE BOOL "" FORCE)
set(ENABLE_CAT           OFF CACHE BOOL "" FORCE)
set(ENABLE_UNZIP         OFF CACHE BOOL "" FORCE)
set(ENABLE_INSTALL       OFF CACHE BOOL "" FORCE)
set(ENABLE_OPENSSL       OFF CACHE BOOL "" FORCE)
set(ENABLE_MBEDTLS       OFF CACHE BOOL "" FORCE)
set(ENABLE_NETTLE        OFF CACHE BOOL "" FORCE)
set(ENABLE_LIBB2         OFF CACHE BOOL "" FORCE)
set(ENABLE_LZ4           OFF CACHE BOOL "" FORCE)
set(ENABLE_LZO           OFF CACHE BOOL "" FORCE)
set(ENABLE_LZMA          OFF CACHE BOOL "" FORCE)  # no emscripten port for liblzma → skip 7z/xz
set(ENABLE_ZSTD          OFF CACHE BOOL "" FORCE)
set(ENABLE_LIBXML2       OFF CACHE BOOL "" FORCE)  # xar; not interesting in wasm
set(ENABLE_EXPAT         OFF CACHE BOOL "" FORCE)
set(ENABLE_PCREPOSIX     OFF CACHE BOOL "" FORCE)
set(ENABLE_PCRE2POSIX    OFF CACHE BOOL "" FORCE)
set(ENABLE_XATTR         OFF CACHE BOOL "" FORCE)
set(ENABLE_ACL           OFF CACHE BOOL "" FORCE)
set(ENABLE_ICONV         OFF CACHE BOOL "" FORCE)
set(ENABLE_COVERAGE      OFF CACHE BOOL "" FORCE)

add_subdirectory(${LIBARCHIVE_ROOT} ${CMAKE_BINARY_DIR}/libarchive EXCLUDE_FROM_ALL)

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

add_executable(archive src/wrapper.cpp)
target_include_directories(archive PRIVATE ${LIBARCHIVE_ROOT}/libarchive)
target_link_libraries(archive PRIVATE archive_static aglet_plugin_sdk_c)
set_target_properties(archive PROPERTIES SUFFIX ".wasm")
