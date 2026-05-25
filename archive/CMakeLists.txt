# Build archive.wasm —— libarchive standalone via emscripten.
# Read: zip / tar / tar.{gz,bz2,xz,zst} / rar (4 + 5) / ar / cpio / iso
# Write: zip / tar / tar.{gz,xz,zst}

cmake_minimum_required(VERSION 3.16)
project(AgletArchivePlugin C CXX)

if(NOT DEFINED ENV{LIBARCHIVE_ROOT})
    message(FATAL_ERROR "LIBARCHIVE_ROOT env must point at libarchive source root")
endif()
if(NOT DEFINED ENV{XZ_ROOT})
    message(FATAL_ERROR "XZ_ROOT env must point at xz-utils source root")
endif()
if(NOT DEFINED ENV{ZSTD_ROOT})
    message(FATAL_ERROR "ZSTD_ROOT env must point at zstd source root")
endif()
set(LIBARCHIVE_ROOT $ENV{LIBARCHIVE_ROOT})
set(XZ_ROOT         $ENV{XZ_ROOT})
set(ZSTD_ROOT       $ENV{ZSTD_ROOT})

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

# ── xz (liblzma) — vendored static build ────────────────────────────────────
# emscripten has no port for liblzma so we build from source. xz CMakeLists
# is well-behaved; we just turn off the executable + tools.
set(XZ_TOOL_LZMAINFO       OFF CACHE BOOL "" FORCE)
set(XZ_TOOL_XZDEC          OFF CACHE BOOL "" FORCE)
set(XZ_TOOL_XZ             OFF CACHE BOOL "" FORCE)
set(XZ_DOC                 OFF CACHE BOOL "" FORCE)
set(XZ_NLS                 OFF CACHE BOOL "" FORCE)
add_subdirectory(${XZ_ROOT} ${CMAKE_BINARY_DIR}/xz EXCLUDE_FROM_ALL)

# Tell libarchive where to find liblzma. The xz CMakeLists exports a
# `liblzma` target whose include directory is the public headers dir;
# `lzma.h` is at src/liblzma/api/lzma.h.
set(LIBLZMA_FOUND       TRUE                            CACHE BOOL   "" FORCE)
set(LIBLZMA_INCLUDE_DIR "${XZ_ROOT}/src/liblzma/api"    CACHE PATH   "" FORCE)
set(LIBLZMA_LIBRARY     liblzma                         CACHE STRING "" FORCE)
set(LIBLZMA_LIBRARIES   liblzma                         CACHE STRING "" FORCE)
set(LIBLZMA_HAS_AUTO_DECODER TRUE                       CACHE BOOL   "" FORCE)
set(LIBLZMA_HAS_EASY_ENCODER TRUE                       CACHE BOOL   "" FORCE)
set(LIBLZMA_HAS_LZMA_PRESET  TRUE                       CACHE BOOL   "" FORCE)

# ── zstd — vendored static build ────────────────────────────────────────────
# zstd's CMakeLists lives in build/cmake/, not the repo root. Disable the
# program / tests / shared lib so we only get the static library.
set(ZSTD_BUILD_PROGRAMS    OFF CACHE BOOL "" FORCE)
set(ZSTD_BUILD_TESTS       OFF CACHE BOOL "" FORCE)
set(ZSTD_BUILD_SHARED      OFF CACHE BOOL "" FORCE)
set(ZSTD_BUILD_STATIC      ON  CACHE BOOL "" FORCE)
set(ZSTD_LEGACY_SUPPORT    OFF CACHE BOOL "" FORCE)
set(ZSTD_MULTITHREAD_SUPPORT OFF CACHE BOOL "" FORCE)
add_subdirectory(${ZSTD_ROOT}/build/cmake ${CMAKE_BINARY_DIR}/zstd EXCLUDE_FROM_ALL)

set(ZSTD_FOUND       TRUE                       CACHE BOOL   "" FORCE)
set(ZSTD_INCLUDE_DIR "${ZSTD_ROOT}/lib"          CACHE PATH   "" FORCE)
set(ZSTD_LIBRARY     libzstd_static              CACHE STRING "" FORCE)
set(ZSTD_LIBRARIES   libzstd_static              CACHE STRING "" FORCE)
# CHECK_FUNCTION_EXISTS in libarchive's zstd block can't resolve the
# CMake target name `libzstd_static` to a -l flag → HAVE_LIBZSTD stays
# undefined → libarchive's runtime falls back to spawning the `zstd`
# CLI subprocess (which doesn't exist in the wasm sandbox). Pre-define
# the cache var so the configure-time check is a no-op.
set(HAVE_LIBZSTD              1 CACHE BOOL "" FORCE)
set(HAVE_ZSTD_compressStream  1 CACHE BOOL "" FORCE)
set(HAVE_ZSTD_minCLevel       1 CACHE BOOL "" FORCE)

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
set(ENABLE_LZMA          ON  CACHE BOOL "" FORCE)  # vendored xz above
set(ENABLE_ZSTD          ON  CACHE BOOL "" FORCE)  # vendored zstd above
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
# Link order matters: liblzma + libzstd_static must come after archive_static
# so libarchive's references resolve. aglet_plugin_sdk_c is INTERFACE so order
# is irrelevant there.
target_link_libraries(archive PRIVATE archive_static liblzma libzstd_static aglet_plugin_sdk_c)
set_target_properties(archive PROPERTIES SUFFIX ".wasm")
