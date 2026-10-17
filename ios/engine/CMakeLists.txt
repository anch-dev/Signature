cmake_minimum_required(VERSION 3.21)
project(signature_engine LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Checkout of https://github.com/ServeurpersoCom/acestep.cpp with its ggml
# submodule. build-engine.sh clones it to ../vendor/acestep.cpp.
set(ACESTEP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../vendor/acestep.cpp" CACHE PATH "acestep.cpp source")
if(NOT EXISTS "${ACESTEP_DIR}/src/pipeline-synth.h")
    message(FATAL_ERROR "acestep.cpp not found at ${ACESTEP_DIR}. Run scripts/build-engine.sh")
endif()

# DiT tensor names exceed ggml's default 64-char limit (same as upstream).
add_compile_definitions(GGML_MAX_NAME=128)

# ggml (Metal on iOS, CPU elsewhere), built static.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
add_subdirectory(${ACESTEP_DIR}/ggml ggml)

add_library(yyjson STATIC ${ACESTEP_DIR}/vendor/yyjson/yyjson.c)
target_include_directories(yyjson PUBLIC ${ACESTEP_DIR}/vendor/yyjson)
target_compile_options(yyjson PRIVATE -w)

# acestep.cpp core pipeline + the C bridge, one static library.
add_library(acestep_bridge STATIC
    ${ACESTEP_DIR}/src/request.cpp
    ${ACESTEP_DIR}/src/model-store.cpp
    ${ACESTEP_DIR}/src/pipeline-lm.cpp
    ${ACESTEP_DIR}/src/pipeline-synth.cpp
    ${ACESTEP_DIR}/src/pipeline-synth-ops.cpp
    ${ACESTEP_DIR}/src/pipeline-understand.cpp
    src/ace_bridge.cpp
)
target_include_directories(acestep_bridge PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_include_directories(acestep_bridge PRIVATE ${ACESTEP_DIR}/src ${ACESTEP_DIR})
target_include_directories(acestep_bridge SYSTEM PRIVATE ${ACESTEP_DIR}/ggml/include)
target_compile_options(acestep_bridge PRIVATE -w)
target_link_libraries(acestep_bridge PUBLIC yyjson ggml)
foreach(backend base cpu blas metal vulkan)
    if(TARGET ggml-${backend})
        target_link_libraries(acestep_bridge PUBLIC ggml-${backend})
    endif()
endforeach()
find_package(Threads REQUIRED)
target_link_libraries(acestep_bridge PUBLIC Threads::Threads)

option(SIGNATURE_SMOKE "Build the desktop smoke-test CLI" OFF)
if(SIGNATURE_SMOKE)
    add_executable(signature-smoke tools/smoke.c)
    target_link_libraries(signature-smoke PRIVATE acestep_bridge)
    set_target_properties(signature-smoke PROPERTIES LINKER_LANGUAGE CXX)
endif()
