# {{Id}} plugin build — standalone wasm via emscripten.
#
# Mirrors the layout of the bundled plugins (barcode / image / archive):
#   STANDALONE_WASM=1   single .wasm output, no JS glue
#   FILESYSTEM=0        pure-compute, no virtual FS
#   ALLOW_MEMORY_GROWTH dynamic linear-memory growth
#   --no-entry          no main(); exports come from AGLET_PLUGIN_EXPORTS

cmake_minimum_required(VERSION 3.16)
project(Aglet{{Id}}Plugin CXX)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Release" CACHE STRING "" FORCE)
endif()

add_compile_options(-fno-exceptions)
add_link_options(-fno-exceptions)

set(CMAKE_EXE_LINKER_FLAGS
    "${CMAKE_EXE_LINKER_FLAGS} \
     -s STANDALONE_WASM=1 \
     -s FILESYSTEM=0 \
     -s ALLOW_MEMORY_GROWTH=1 \
     -s INITIAL_MEMORY=4MB \
     -Wl,--no-entry")

# Aglet plugin SDK (header-only) — sits at ../sdk/c/ in the repo.
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../sdk/c
                 ${CMAKE_BINARY_DIR}/aglet_plugin_sdk_c)

add_executable({{id}} src/wrapper.cpp)
target_link_libraries({{id}} PRIVATE aglet_plugin_sdk_c)
set_target_properties({{id}} PROPERTIES SUFFIX ".wasm")
