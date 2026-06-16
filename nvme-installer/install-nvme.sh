#!/usr/bin/env bash
set -euo pipefail

AUTO_CONFIRM=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) AUTO_CONFIRM=true; shift ;;
    *) break ;;
  esac
done

NVME_DEV="${1:-/dev/nvme0n1}"
TARGET_TOPLEVEL="@targetToplevel@"
TARGET_FIRMWARE="@targetFirmware@"
FIRMWARE_PARTITION_SIZE="@firmwarePartitionSize@"
SFDISK="@sfdisk@"
PARTPROBE="@partprobe@"
MKFS_VFAT="@mkfsVfat@"
MKFS_EXT4="@mkfsExt4@"
NIX="@nix@"
NIX_ENV="@nixEnv@"
RPI_EEPROM_CONFIG="@rpiEepromConfig@"
USE_UBOOT="@useUboot@"
EXTLINUX_POPULATE_CMD="@extlinuxPopulateCmd@"

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: must run as root"
  exit 1
fi

if [ ! -b "$NVME_DEV" ]; then
  echo "Error: $NVME_DEV not found. Is an NVMe drive connected?"
  echo "Available block devices:"
  lsblk
  exit 1
fi

echo "=========================================="
echo "NixOS NVMe Installer for Raspberry Pi 5"
echo "=========================================="
echo ""
echo "Target device: $NVME_DEV"
echo "NixOS closure: $TARGET_TOPLEVEL"
echo ""
echo "WARNING: This will ERASE ALL DATA on $NVME_DEV"
echo ""
if [ "$AUTO_CONFIRM" = "false" ]; then
  read -rp "Continue? [y/N] " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""
echo ">>> Unmounting any existing partitions on $NVME_DEV..."
findmnt -rno SOURCE,TARGET | grep -F "${NVME_DEV}" | while read -r src mnt; do
  echo "    Unmounting $src ($mnt)"
  umount "$mnt" || umount -l "$mnt"
done || true

echo ">>> Partitioning $NVME_DEV..."
"$SFDISK" "$NVME_DEV" <<EOF
label: dos

size=${FIRMWARE_PARTITION_SIZE}, type=b
type=83
EOF

sleep 1
"$PARTPROBE" "$NVME_DEV"
sleep 1

FIRMWARE_PART="${NVME_DEV}p1"
ROOT_PART="${NVME_DEV}p2"

echo ">>> Formatting firmware partition ($FIRMWARE_PART) as FAT32..."
"$MKFS_VFAT" -F 32 -n FIRMWARE "$FIRMWARE_PART"

echo ">>> Formatting root partition ($ROOT_PART) as ext4..."
"$MKFS_EXT4" -F -L NIXOS_NVME "$ROOT_PART"

echo ">>> Mounting partitions..."
MOUNT_ROOT=$(mktemp -d)
mount "$ROOT_PART" "$MOUNT_ROOT"

cleanup() {
  echo ">>> Cleaning up mounts..."
  umount "$MOUNT_ROOT/boot" 2>/dev/null || true
  umount "$MOUNT_ROOT" 2>/dev/null || true
  rmdir "$MOUNT_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

echo ">>> Copying NixOS closure to NVMe (this may take a while)..."
mkdir -p "$MOUNT_ROOT/nix/store"

# Copy all store paths needed by the target system
"$NIX" --extra-experimental-features nix-command copy --no-check-sigs --to "local?root=$MOUNT_ROOT" "$TARGET_TOPLEVEL"

echo ">>> Setting up system profile..."
mkdir -p "$MOUNT_ROOT/nix/var/nix/profiles"
"$NIX_ENV" --store "local?root=$MOUNT_ROOT" \
  --profile "$MOUNT_ROOT/nix/var/nix/profiles/system" \
  --set "$TARGET_TOPLEVEL"

echo ">>> Installing /sbin/init..."
mkdir -p "$MOUNT_ROOT/sbin"
ln -sf /nix/var/nix/profiles/system/init "$MOUNT_ROOT/sbin/init"

echo ">>> Creating /etc/NIXOS marker..."
mkdir -p "$MOUNT_ROOT/etc"
touch "$MOUNT_ROOT/etc/NIXOS"

echo ">>> Populating firmware partition..."
mkdir -p "$MOUNT_ROOT/boot"
mount "$FIRMWARE_PART" "$MOUNT_ROOT/boot"
cp -r "$TARGET_FIRMWARE"/. "$MOUNT_ROOT/boot/"

if [ -n "$USE_UBOOT" ]; then
  echo ">>> Setting up extlinux boot configuration (u-boot)..."
  $EXTLINUX_POPULATE_CMD -c "$TARGET_TOPLEVEL" -d "$MOUNT_ROOT/boot"
fi

echo ">>> Syncing..."
sync

echo ">>> Configuring EEPROM for NVMe PCIe probe..."
# Set PCIE_PROBE=1 for non-HAT+ NVMe adapters
# Keep default boot order (SD, USB, NVMe)
EEPROM_CONFIG=$("$RPI_EEPROM_CONFIG" 2>/dev/null || true)
if [ -n "$EEPROM_CONFIG" ]; then
  TMPCONF=$(mktemp)
  echo "${EEPROM_CONFIG//PCIE_PROBE=*/PCIE_PROBE=1}" > "$TMPCONF"
  # Add PCIE_PROBE if it doesn't exist
  grep -q '^PCIE_PROBE=' "$TMPCONF" || echo "PCIE_PROBE=1" >> "$TMPCONF"
  "$RPI_EEPROM_CONFIG" --apply "$TMPCONF" || {
    echo "WARNING: Failed to apply EEPROM config. You may need to manually set:"
    echo "  PCIE_PROBE=1"
    echo "  using: sudo rpi-eeprom-config --edit"
  }
  rm -f "$TMPCONF"
else
  echo "WARNING: Could not read EEPROM config. You may need to manually set:"
  echo "  sudo rpi-eeprom-config --edit"
  echo "  PCIE_PROBE=1"
fi

echo ""
echo "=========================================="
echo "Installation complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Power off the Raspberry Pi"
echo "  2. Remove the SD card"
echo "  3. The Pi will boot from NVMe (default boot order: SD, USB, NVMe)"
echo ""
echo "EEPROM has been configured with PCIE_PROBE=1."
echo "The change takes effect on next reboot."
echo ""
