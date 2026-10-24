# ============================================================
#  SpectruLenPor — native Moondream engine build
# ============================================================
#  Prerequisite (one-time):
#    cd android/app/src/main/cpp
#    git clone --depth 1 --recursive https://github.com/ggerganov/llama.cpp
#  (llama.cpp supplies: llama.h, clip.h, llava.h and their .c/.cpp sources)
#
#  Then wire this in android/app/build.gradle:
#    android {
#      externalNativeBuild { cmake { path "src/main/cpp/CMakeLists.txt" } }
#      defaultConfig { externalNativeBuild { cmake { abiFilters "arm64-v8a" } } }
#    }
# ============================================================

cmake_minimum_required(VERSION 3.22)
project(moondream_jni C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---- llama.cpp static libs (from the cloned submodule) ----
set(LLAMA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp)

add_subdirectory(${LLAMA_DIR} llama.cpp-build EXCLUDE_FROM_ALL)

# ---- JNI bridge ----
add_library(moondream_jni SHARED moondream_jni.cpp)

target_include_directories(moondream_jni PRIVATE
    ${LLAMA_DIR}
    ${LLAMA_DIR}/examples/llava
)

find_library(log-lib log)

target_link_libraries(moondream_jni
    llama            # llama.cpp core
    common           # llama.cpp helpers
    ${log-lib}
)

# Optimization: -O3 + NEON (ARM64) — mobile inference is compute-bound.
target_compile_options(moondream_jni PRIVATE
    -O3
    -ffast-math
    $<$<COMPILE_LANGUAGE:CXX>:-fexceptions>
)
