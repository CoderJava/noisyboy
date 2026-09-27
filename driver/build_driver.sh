#!/bin/bash
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )"
DIR="$PROJECT_ROOT/driver"
BUILD_DIR="$PROJECT_ROOT/build/driver_bundle"
BUNDLE_DIR="$BUILD_DIR/NoisyBoyAudio.driver"
MACOS_DIR="$BUNDLE_DIR/Contents/MacOS"

echo "==> Building NoisyBoyAudio CoreAudio HAL Driver..."
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"

clang -bundle -O3 -arch arm64 -arch x86_64 \
  -DkNumber_Of_Channels=2 \
  -framework CoreAudio -framework CoreFoundation -framework AudioToolbox -framework Accelerate \
  "$DIR/NoisyBoyAudio.c" -o "$MACOS_DIR/NoisyBoyAudio"

cp "$DIR/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"

echo "✓ NoisyBoyAudio.driver successfully built at: $BUNDLE_DIR"
