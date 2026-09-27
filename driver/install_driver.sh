#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
"$DIR/build_driver.sh"

DEST="/Library/Audio/Plug-Ins/HAL/NoisyBoyAudio.driver"

echo "==> Installing NoisyBoyAudio.driver to $DEST..."
echo "Note: Administrator password (sudo) is required to install CoreAudio HAL drivers."

sudo rm -rf "$DEST"
sudo cp -R "$DIR/../build/driver_bundle/NoisyBoyAudio.driver" "$DEST"
sudo chown -R root:wheel "$DEST"
sudo chmod -R 755 "$DEST"

echo "==> Restarting CoreAudio daemon (coreaudiod)..."
sudo killall coreaudiod 2>/dev/null || true

echo "✓ NoisyBoy Audio Driver installed and active!"
