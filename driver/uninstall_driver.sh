#!/bin/bash
set -e

DEST="/Library/Audio/Plug-Ins/HAL/NoisyBoyAudio.driver"

echo "==> Uninstalling NoisyBoyAudio.driver from $DEST..."
if [ -d "$DEST" ]; then
    sudo rm -rf "$DEST"
    echo "==> Restarting CoreAudio daemon (coreaudiod)..."
    sudo killall coreaudiod 2>/dev/null || true
    echo "✓ NoisyBoy Audio Driver uninstalled successfully."
else
    echo "Driver not found in $DEST. Nothing to uninstall."
fi
