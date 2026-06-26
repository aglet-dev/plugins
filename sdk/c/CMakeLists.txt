# INTERFACE library exposing the C/C++ SDK header. Plugin authors who already
# `add_subdirectory(...)` this from their CMake project can link
# `aglet_plugin_sdk_c` instead of manually wiring an include directory.
#
# Equivalent inline form (no CMake target):
#   target_include_directories(<plugin> PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../sdk/c)
#
# Header-only, C++17.

cmake_minimum_required(VERSION 3.16)

add_library(aglet_plugin_sdk_c INTERFACE)
target_include_directories(aglet_plugin_sdk_c INTERFACE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(aglet_plugin_sdk_c INTERFACE cxx_std_17)
