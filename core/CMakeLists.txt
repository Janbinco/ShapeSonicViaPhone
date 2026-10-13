# Portable ShapeSonic core. Builds a static library and its tests on any
# desktop; the iOS app compiles src/ directly, and an Android app would add it
# with add_subdirectory() from its own CMake build.
cmake_minimum_required(VERSION 3.16)
project(shapesonic_core CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_package(Threads REQUIRED)
add_library(shapesonic STATIC
  src/geometry.cpp src/octree.cpp src/shape.cpp src/sonify.cpp src/mixer.cpp)
target_include_directories(shapesonic PUBLIC include)
target_link_libraries(shapesonic PUBLIC Threads::Threads)
if(NOT MSVC)
  target_compile_options(shapesonic PRIVATE -Wall -Wextra)
endif()

enable_testing()
add_executable(core_tests tests/core_tests.cpp)
target_link_libraries(core_tests shapesonic)
target_compile_definitions(core_tests PRIVATE MODELS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../models")
add_test(NAME core_tests COMMAND core_tests)
