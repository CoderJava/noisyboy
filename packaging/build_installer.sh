#!/bin/bash
set -e

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )"
DIST_DIR="$PROJECT_ROOT/dist"
TEMP_BUILD="$PROJECT_ROOT/build/packaging_temp"
PACKAGING_SCRIPTS="$PROJECT_ROOT/packaging/scripts"

VERSION="1.0.0"
IDENTIFIER="com.noisyboy.app"

echo "=================================================="
echo "    Building NoisyBoy macOS Installer Package     "
echo "=================================================="

# 1. Clean & setup directories
rm -rf "$DIST_DIR" "$TEMP_BUILD"
mkdir -p "$DIST_DIR" "$TEMP_BUILD/packages" "$TEMP_BUILD/dmg_root"

# 2. Build Driver (Universal Binary)
echo "==> [1/5] Building NoisyBoy Virtual Audio Driver..."
"$PROJECT_ROOT/driver/build_driver.sh"

DRIVER_BUNDLE="$PROJECT_ROOT/build/driver_bundle/NoisyBoyAudio.driver"
if [ ! -d "$DRIVER_BUNDLE" ]; then
    echo "Error: Driver bundle not found at $DRIVER_BUNDLE"
    exit 1
fi

# 3. Build Flutter macOS Release App
echo "==> [2/5] Building Flutter macOS Release App..."
cd "$PROJECT_ROOT"
flutter build macos --release

APP_BUNDLE="$PROJECT_ROOT/build/macos/Build/Products/Release/noisyboy.app"
if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: App bundle not found at $APP_BUNDLE"
    exit 1
fi

# 4. Package App Component (/Applications/NoisyBoy.app) with Relocation DISABLED
echo "==> [3/5] Packaging NoisyBoy.app component (forcing /Applications install)..."
mkdir -p "$TEMP_BUILD/app_root/Applications"
cp -R "$APP_BUNDLE" "$TEMP_BUILD/app_root/Applications/NoisyBoy.app"

pkgbuild --analyze --root "$TEMP_BUILD/app_root" "$TEMP_BUILD/app_comp.plist"
sed -i '' 's/<key>BundleIsRelocatable<\/key>[[:space:]]*<true\/>/<key>BundleIsRelocatable<\/key><false\/>/g' "$TEMP_BUILD/app_comp.plist"

pkgbuild --root "$TEMP_BUILD/app_root" \
    --component-plist "$TEMP_BUILD/app_comp.plist" \
    --identifier "${IDENTIFIER}.app" \
    --version "$VERSION" \
    --install-location "/" \
    "$TEMP_BUILD/packages/NoisyBoyApp.pkg"

# 5. Package Driver Component (/Library/Audio/Plug-Ins/HAL/NoisyBoyAudio.driver) with Relocation DISABLED
echo "==> [4/5] Packaging Virtual Driver component..."
mkdir -p "$TEMP_BUILD/driver_root/Library/Audio/Plug-Ins/HAL"
cp -R "$DRIVER_BUNDLE" "$TEMP_BUILD/driver_root/Library/Audio/Plug-Ins/HAL/NoisyBoyAudio.driver"

chmod +x "$PACKAGING_SCRIPTS/postinstall"

pkgbuild --analyze --root "$TEMP_BUILD/driver_root" "$TEMP_BUILD/driver_comp.plist"
sed -i '' 's/<key>BundleIsRelocatable<\/key>[[:space:]]*<true\/>/<key>BundleIsRelocatable<\/key><false\/>/g' "$TEMP_BUILD/driver_comp.plist"

pkgbuild --root "$TEMP_BUILD/driver_root" \
    --component-plist "$TEMP_BUILD/driver_comp.plist" \
    --identifier "${IDENTIFIER}.driver" \
    --version "$VERSION" \
    --install-location "/" \
    --scripts "$PACKAGING_SCRIPTS" \
    "$TEMP_BUILD/packages/NoisyBoyDriver.pkg"

# 6. Generate Unified Product Installer (.pkg)
echo "==> [5/5] Creating unified NoisyBoy-Installer.pkg..."

cat << EOF > "$TEMP_BUILD/Distribution.xml"
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>NoisyBoy — AI Noise Suppression</title>
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <choices-outline>
        <line choice="choiceApp"/>
        <line choice="choiceDriver"/>
    </choices-outline>
    <choice id="choiceApp" title="NoisyBoy Application (/Applications/NoisyBoy.app)">
        <pkg-ref id="${IDENTIFIER}.app"/>
    </choice>
    <choice id="choiceDriver" title="NoisyBoy Virtual Audio Driver">
        <pkg-ref id="${IDENTIFIER}.driver"/>
    </choice>
    <pkg-ref id="${IDENTIFIER}.app" version="$VERSION" onConclusion="none">NoisyBoyApp.pkg</pkg-ref>
    <pkg-ref id="${IDENTIFIER}.driver" version="$VERSION" onConclusion="none">NoisyBoyDriver.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild --distribution "$TEMP_BUILD/Distribution.xml" \
    --package-path "$TEMP_BUILD/packages" \
    "$DIST_DIR/NoisyBoy-Installer.pkg"

# 7. Create Disk Image (.dmg) with PKG, App bundle, and Applications Shortcut
echo "==> Creating NoisyBoy-Installer.dmg..."
cp "$DIST_DIR/NoisyBoy-Installer.pkg" "$TEMP_BUILD/dmg_root/"
cp -R "$APP_BUNDLE" "$TEMP_BUILD/dmg_root/NoisyBoy.app"
ln -s /Applications "$TEMP_BUILD/dmg_root/Applications"

# Add README note into DMG
cat << EOF > "$TEMP_BUILD/dmg_root/README.txt"
NoisyBoy — AI Noise Suppression for macOS

Pilihan Instalasi:
1. Rekomendasi: Klik ganda 'NoisyBoy-Installer.pkg' untuk memasang Aplikasi NoisyBoy ke /Applications dan mengaktifkan Virtual Driver secara otomatis.
2. Atau geser 'NoisyBoy.app' ke folder 'Applications'.

Setelah instalasi:
- Buka NoisyBoy dari Launchpad atau folder Applications.
- Di Google Meet, Zoom, atau Discord: Pilih 'NoisyBoy Audio' sebagai Microphone Anda.

Selesai & Selamat Menikmati Suara Jernih!
EOF

hdiutil create -volname "NoisyBoy Installer" \
    -srcfolder "$TEMP_BUILD/dmg_root" \
    -ov -format UDZO \
    "$DIST_DIR/NoisyBoy-Installer.dmg"

# Clean temporary files
rm -rf "$TEMP_BUILD"

echo ""
echo "=================================================="
echo "✓ BUILD SUCCESSFUL!"
echo "Artifacts generated in dist/:"
echo "  1. PKG Installer : $DIST_DIR/NoisyBoy-Installer.pkg"
echo "  2. DMG Image     : $DIST_DIR/NoisyBoy-Installer.dmg"
echo "=================================================="
