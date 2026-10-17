cmake_minimum_required(VERSION 3.22.1)
project(signature_android LANGUAGES C CXX)

# Repo root (android/app/src/main/cpp -> ../../../../..).
get_filename_component(SIG_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
set(ACESTEP_DIR "${SIG_ROOT}/ios/vendor/acestep.cpp" CACHE PATH "acestep.cpp checkout (ios/scripts/fetch-acestep.sh)")

option(SIGNATURE_VULKAN "Build the ggml Vulkan backend (GPU)" ON)

set(GGML_VULKAN ${SIGNATURE_VULKAN} CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)            # ggml's own threadpool; no libomp to ship
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)   # 2019+ phones
set(GGML_METAL OFF CACHE BOOL "" FORCE)

# Shared engine: acestep.cpp + ggml + the C bridge (same code as iOS).
add_subdirectory("${SIG_ROOT}/ios/engine" engine)

add_library(signature SHARED jni_bridge.cpp)
target_link_libraries(signature PRIVATE acestep_bridge android log)
target_compile_options(signature PRIVATE -O2)
# 16 KB page size support (Android 15+ devices).
target_link_options(signature PRIVATE "-Wl,-z,max-page-size=16384")
