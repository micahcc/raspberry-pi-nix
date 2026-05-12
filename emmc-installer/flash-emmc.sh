#!/usr/bin/env bash
set -euo pipefail

RPIBOOT="@rpiboot@"
ZSTD="@zstd@"
LSUSB="@lsusb@"
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
  echo "If no device is specified, the script will auto-detect the CM eMMC."
  echo "If the eMMC is not yet exposed, rpiboot will be run automatically."
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: must run as root (rpiboot and dd require root access)"
  exit 1
fi

# Find block devices backed by usb-storage with a Raspberry Pi USB ancestor
find_rpi_emmc() {
  for dev in /sys/block/sd*; do
    [ -d "$dev" ] || continue
    # Check the device uses usb-storage
    if readlink -f "$dev/device" | grep -q "usb-storage"; then
      # Walk up to find the USB device and check vendor/product
      usb_dev=$(readlink -f "$dev/device/../..")
      if [ -f "$usb_dev/idVendor" ] && [ -f "$usb_dev/idProduct" ]; then
        vendor=$(cat "$usb_dev/idVendor")
        product=$(cat "$usb_dev/idProduct")
        # Broadcom RPi: 0a5c:0104
        if [ "$vendor" = "0a5c" ] && [ "$product" = "0104" ]; then
          echo "/dev/$(basename "$dev")"
          return 0
        fi
      fi
    fi
  done
  return 1
}

# Check if RPi is connected in USB boot mode (before rpiboot exposes eMMC)
rpi_in_boot_mode() {
  "$LSUSB" -d 2e8a:0003 > /dev/null 2>&1 || "$LSUSB" -d 0a5c:0001 > /dev/null 2>&1
}

TARGET_DEV="${1:-}"

if [ -z "$TARGET_DEV" ]; then
  # First check if eMMC is already exposed (rpiboot already ran)
  if TARGET_DEV=$(find_rpi_emmc); then
    echo ">>> Found Raspberry Pi eMMC already exposed: $TARGET_DEV"
  elif rpi_in_boot_mode; then
    echo ">>> Raspberry Pi detected in USB boot mode, running rpiboot..."
    "$RPIBOOT"

    echo ">>> Waiting for eMMC block device to appear..."
    for attempt in $(seq 1 30); do
      if TARGET_DEV=$(find_rpi_emmc); then
        break
      fi
      printf "\r    waiting... (%ds)" "$attempt"
      sleep 1
    done
    echo ""

    if [ -z "$TARGET_DEV" ]; then
      echo "Error: No Raspberry Pi eMMC device appeared after rpiboot."
      exit 1
    fi
  else
    echo "Error: No Raspberry Pi Compute Module detected."
    echo ""
    echo "Ensure that:"
    echo "  - The 'disable eMMC boot' jumper is set"
    echo "  - The IO board is connected via USB to this computer"
    echo "  - The CM is powered on"
    echo ""
    echo "You can also specify the device manually: flash-emmc /dev/sdX"
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
