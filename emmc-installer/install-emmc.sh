#!/usr/bin/env bash
set -euo pipefail

TARGET_TOPLEVEL="@targetToplevel@"
TARGET_FIRMWARE="@targetFirmware@"
FIRMWARE_PARTITION_SIZE="@firmwarePartitionSize@"
SFDISK="@sfdisk@"
PARTPROBE="@partprobe@"
MKFS_VFAT="@mkfsVfat@"
MKFS_EXT4="@mkfsExt4@"
NIX="@nix@"
NIX_ENV="@nixEnv@"

# Find the eMMC device. On CM4/CM5, the eMMC and SD card are both mmcblk
# devices. We identify eMMC by checking the sysfs "type" attribute:
# SD cards report "SD", eMMC reports "MMC".
find_emmc_device() {
  for dev in /sys/block/mmcblk*; do
    [ -d "$dev" ] || continue
    devname=$(basename "$dev")
    # Skip boot partitions (mmcblk0boot0, etc.)
    [[ "$devname" == *boot* ]] && continue
    [[ "$devname" == *rpmb* ]] && continue
    type_file="$dev/device/type"
    if [ -f "$type_file" ] && [ "$(cat "$type_file")" = "MMC" ]; then
      echo "/dev/$devname"
      return 0
    fi
  done
  return 1
}

EMMC_DEV="${1:-}"
if [ -z "$EMMC_DEV" ]; then
  EMMC_DEV=$(find_emmc_device) || {
    echo "Error: Could not auto-detect eMMC device."
    echo "Available block devices:"
    lsblk
    echo ""
    echo "Usage: install-emmc [/dev/mmcblkX]"
    exit 1
  }
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: must run as root"
  exit 1
fi

if [ ! -b "$EMMC_DEV" ]; then
  echo "Error: $EMMC_DEV not found. Is this a Compute Module with eMMC?"
  echo "Available block devices:"
  lsblk
  exit 1
fi

# Safety check: refuse to install onto the device we booted from
BOOT_DEV=$(lsblk -npo PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)
if [ "$EMMC_DEV" = "$BOOT_DEV" ]; then
  echo "Error: $EMMC_DEV is the current boot device. Refusing to overwrite."
  echo "Are you sure you identified the correct eMMC device?"
  exit 1
fi

echo "=========================================="
echo " NixOS eMMC Installer for Raspberry Pi"
echo "=========================================="
echo ""
echo "Target device: $EMMC_DEV"
echo "NixOS closure: $TARGET_TOPLEVEL"
echo ""
echo "WARNING: This will ERASE ALL DATA on $EMMC_DEV"
echo ""
read -rp "Continue? [y/N] " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo ">>> Unmounting any existing partitions on $EMMC_DEV..."
findmnt -rno SOURCE,TARGET | grep -F "${EMMC_DEV}" | while read -r src mnt; do
  echo "    Unmounting $src ($mnt)"
  umount "$mnt" || umount -l "$mnt"
done || true

echo ">>> Partitioning $EMMC_DEV..."
"$SFDISK" "$EMMC_DEV" <<EOF
label: dos

size=${FIRMWARE_PARTITION_SIZE}, type=b
type=83
EOF

sleep 1
"$PARTPROBE" "$EMMC_DEV"
sleep 1

FIRMWARE_PART="${EMMC_DEV}p1"
ROOT_PART="${EMMC_DEV}p2"

echo ">>> Formatting firmware partition ($FIRMWARE_PART) as FAT32..."
"$MKFS_VFAT" -F 32 -n FIRMWARE "$FIRMWARE_PART"

echo ">>> Formatting root partition ($ROOT_PART) as ext4..."
"$MKFS_EXT4" -F -L NIXOS_EMMC "$ROOT_PART"

echo ">>> Mounting partitions..."
MOUNT_ROOT=$(mktemp -d)
mount "$ROOT_PART" "$MOUNT_ROOT"
mkdir -p "$MOUNT_ROOT/boot/firmware"
mount "$FIRMWARE_PART" "$MOUNT_ROOT/boot/firmware"

cleanup() {
  echo ">>> Cleaning up mounts..."
  umount "$MOUNT_ROOT/boot/firmware" 2>/dev/null || true
  umount "$MOUNT_ROOT" 2>/dev/null || true
  rmdir "$MOUNT_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

echo ">>> Copying NixOS closure to eMMC (this may take a while)..."
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
cp -r "$TARGET_FIRMWARE"/. "$MOUNT_ROOT/boot/firmware/"

echo ">>> Syncing..."
sync

echo ""
echo "=========================================="
echo "Installation complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Power off the Raspberry Pi"
echo "  2. Remove the SD card"
echo "  3. The CM will boot from eMMC (default boot order)"
echo ""
