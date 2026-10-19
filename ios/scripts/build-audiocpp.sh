#!/usr/bin/env bash
# Builds audio.cpp's C API (YuE2 only, Metal) for iOS arm64 and wraps it as
# AudioCpp.framework. The app dlopens it for on-device YuE2 (experimental).
# audio.cpp carries its own ggml; the C API library is built with hidden
# visibility so only audiocpp_* symbols are exported and nothing clashes with
# the ACE-Step engine's ggml.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
VER="v0.9.2"
SRC="$HERE/vendor/audio.cpp"
BUILD="$HERE/build/audiocpp-ios"
OUT="$HERE/Frameworks/AudioCpp.framework"

mkdir -p "$HERE/build"
if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch "$VER" https://github.com/0xShug0/audio.cpp "$SRC"
fi

# Signature hook: let the app turn on audio.cpp's stage/timing log and model
# load progress (the CLI's --log), so the in-app terminal shows what YuE2 is
# doing. Appended once to the C API translation unit.
CAPI="$SRC/src/capi/audiocpp.cpp"
if ! grep -q audiocpp_signature_set_logging "$CAPI"; then
    cat >> "$CAPI" <<'CPP'

// ---- Signature (iOS app) hook ----------------------------------------------
#include "engine/framework/core/load_progress.h"
#include "engine/framework/debug/trace.h"
extern "C" __attribute__((visibility("default"))) void audiocpp_signature_set_logging(int enabled) {
    engine::debug::configure_logging(engine::debug::LoggingConfig{enabled != 0, std::nullopt});
    engine::core::set_load_progress_enabled(enabled != 0);
}
CPP
fi

# Deployment target 16.4: audio.cpp uses std::to_chars for floats (iOS 16.3+).
# The app itself supports 16.0; on older iOS the framework just doesn't load
# and on-device YuE2 is unavailable.

# sentencepiece calls set_xcode_property (a macro from its own iOS toolchain
# file) when CMAKE_SYSTEM_NAME is iOS; we build with CMake's native iOS
# support, so provide a no-op instead.
cat > "$HERE/build/audiocpp-noop-xcode.cmake" <<'CM'
if(NOT COMMAND set_xcode_property)
  macro(set_xcode_property TARGET XCODE_PROPERTY XCODE_VALUE XCODE_RELVERSION)
  endmacro()
endif()
CM

cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_PROJECT_INCLUDE_BEFORE="$HERE/build/audiocpp-noop-xcode.cmake" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.4 \
    -DCMAKE_BUILD_TYPE=Release \
    -DAUDIOCPP_BUILD_C_API=ON \
    -DAUDIOCPP_MODEL_SET=custom \
    -DAUDIOCPP_MODELS=yue2 \
    -DAUDIOCPP_BUILD_NATIVE_MODEL_MANAGER=OFF \
    -DENGINE_ENABLE_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DENGINE_ENABLE_OPENMP=OFF \
    -DENGINE_ENABLE_NATIVE_CPU=OFF \
    -DENGINE_ENABLE_LLAMAFILE=OFF \
    -DENGINE_BUILD_EXAMPLES=OFF \
    -DENGINE_BUILD_TESTS=OFF

cmake --build "$BUILD" --target audiocpp --config Release -j "$(sysctl -n hw.ncpu)"

DYLIB="$(find "$BUILD" -name 'libaudiocpp*.dylib' -type f | head -1)"
[ -n "$DYLIB" ] || { echo "libaudiocpp.dylib not found"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$DYLIB" "$OUT/AudioCpp"
install_name_tool -id "@rpath/AudioCpp.framework/AudioCpp" "$OUT/AudioCpp"
cat > "$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>AudioCpp</string>
  <key>CFBundleIdentifier</key><string>com.anchdev.signature.audiocpp</string>
  <key>CFBundleName</key><string>AudioCpp</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${VER#v}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>16.4</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict></plist>
PLIST

echo "== AudioCpp.framework"
ls -lh "$OUT/AudioCpp"
otool -L "$OUT/AudioCpp"
nm -gU "$OUT/AudioCpp" | grep -c " _audiocpp_" | xargs echo "exported audiocpp_* symbols:"
if nm -gU "$OUT/AudioCpp" | grep -q " _ggml_init$"; then
    echo "::warning::ggml symbols are exported from AudioCpp (expected hidden)"
fi
