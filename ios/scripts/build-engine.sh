#!/usr/bin/env bash
# build-engine.sh - compile acestep.cpp + ggml (Metal) + the C bridge into
# ios/Frameworks/AceEngine.xcframework (ios-arm64, static).
#
# Runs on macOS (the GitHub Actions runner). Needs Xcode and CMake.
set -euo pipefail

IOS_MIN="16.0"

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # ios/
VENDOR="$HERE/vendor/acestep.cpp"
BUILD="$HERE/build/engine-ios"
OUT="$HERE/Frameworks/AceEngine.xcframework"

bash "$HERE/scripts/fetch-acestep.sh"

echo "==> Configuring for iOS arm64 (Metal, Accelerate)"
cmake -S "$HERE/engine" -B "$BUILD" -G Xcode \
    -DACESTEP_DIR="$VENDOR" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=ON \
    -DGGML_ACCELERATE=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_CCACHE=OFF

echo "==> Building"
cmake --build "$BUILD" --config Release --target acestep_bridge -- -quiet

echo "==> Merging static libraries"
LIBS=$(find "$BUILD" -path '*Release-iphoneos*' -name '*.a' | sort)
echo "$LIBS" | sed 's/^/    /'
MERGED="$BUILD/libAceEngine.a"
rm -f "$MERGED"
# shellcheck disable=SC2086
libtool -static -o "$MERGED" $LIBS

HDR="$BUILD/headers"
rm -rf "$HDR"
mkdir -p "$HDR"
cp "$HERE/engine/include/ace_bridge.h" "$HDR/"
cat > "$HDR/module.modulemap" <<'EOF'
module AceEngine {
    header "ace_bridge.h"
    link "c++"
    link framework "Metal"
    link framework "Foundation"
    link framework "Accelerate"
    export *
}
EOF

rm -rf "$OUT"
xcodebuild -create-xcframework -library "$MERGED" -headers "$HDR" -output "$OUT"
echo "==> $OUT ($(du -sh "$OUT" | cut -f1))"
