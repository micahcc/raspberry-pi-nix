#!/usr/bin/env bash
set -euo pipefail

RPIBOOT="@rpiboot@"
ZSTD="@zstd@"
IMAGE="@image@"

usage() {
  echo "Usage: flash-emmc [/dev/sdX]"
  echo ""
  echo "Flashes the NixOS eMMC image to a Raspberry Pi Compute Module."
  echo ""
  echo "Steps:"
  echo "  1. Set the CM boot jumper to USB boot mode"
  echo "  2. Connect the CM IO board to this computer via USB"
  echo "  3. Power on the CM"
  echo "  4. Run this script"
  echo ""
  echo "If no device is specified, rpiboot will expose the eMMC and"
  echo "the script will auto-detect the new block device."
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: must run as root (rpiboot and dd require root access)"
  exit 1
fi

TARGET_DEV="${1:-}"

if [ -z "$TARGET_DEV" ]; then
  echo ">>> Running rpiboot to expose eMMC as USB mass storage..."
  # Capture block devices before rpiboot
  BEFORE=$(lsblk -dnpo NAME 2>/dev/null || true)

  "$RPIBOOT"

  echo ">>> Waiting for eMMC block device to appear..."
  for i in $(seq 1 30); do
    AFTER=$(lsblk -dnpo NAME 2>/dev/null || true)
    NEW_DEV=$(comm -13 <(echo "$BEFORE" | sort) <(echo "$AFTER" | sort) | head -1)
    if [ -n "$NEW_DEV" ]; then
      TARGET_DEV="$NEW_DEV"
      break
    fi
    sleep 1
  done

  if [ -z "$TARGET_DEV" ]; then
    echo "Error: No new block device appeared after rpiboot."
    echo "Check that the CM is in USB boot mode and connected."
    exit 1
  fi
fi

if [ ! -b "$TARGET_DEV" ]; then
  echo "Error: $TARGET_DEV is not a block device"
  exit 1
fi

echo ""
echo "=========================================="
echo " NixOS eMMC Flasher for Raspberry Pi CM"
echo "=========================================="
echo ""
echo "Image:  $IMAGE"
echo "Target: $TARGET_DEV"
echo ""
echo "WARNING: This will ERASE ALL DATA on $TARGET_DEV"
echo ""
read -rp "Continue? [y/N] " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
  echo "Aborted."
  exit 0
fi

echo ">>> Flashing image to $TARGET_DEV..."
if [[ "$IMAGE" == *.zst ]]; then
  "$ZSTD" -d --stdout "$IMAGE" | dd of="$TARGET_DEV" bs=4M status=progress conv=fsync
else
  dd if="$IMAGE" of="$TARGET_DEV" bs=4M status=progress conv=fsync
fi

echo ""
echo "=========================================="
echo " Flash complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Power off the CM"
echo "  2. Remove the USB boot jumper (set to eMMC boot)"
echo "  3. Power on - the CM will boot NixOS from eMMC"
echo ""
