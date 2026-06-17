#!/bin/sh
# NixOS kexec boot menu for Raspberry Pi 5
# Runs in initrd, presents generation menu, kexec's into selected generation.

set -e

MOUNT_POINT="/mnt"
PROFILES_DIR="$MOUNT_POINT/nix/var/nix/profiles"
TIMEOUT=${BOOT_MENU_TIMEOUT:-5}

# Colors for menu
RESET="\033[0m"
BOLD="\033[1m"
GREEN="\033[32m"
CYAN="\033[36m"

echo ""
echo -e "${BOLD}NixOS Boot Menu${RESET}"
echo "==============================="
echo ""

# Find NVMe device
NVME_DEV=""
for dev in /dev/nvme0n1p2 /dev/disk/by-label/NIXOS_NVME; do
    if [ -e "$dev" ]; then
        NVME_DEV="$dev"
        break
    fi
done

if [ -z "$NVME_DEV" ]; then
    echo "ERROR: NVMe root partition not found."
    echo "Falling back to default boot..."
    exit 1
fi

# Mount NVMe root
mkdir -p "$MOUNT_POINT"
mount -o ro "$NVME_DEV" "$MOUNT_POINT"

# Collect generations
GENERATIONS=""
COUNT=0

if [ -d "$PROFILES_DIR" ]; then
    for link in $(ls -1t "$PROFILES_DIR"/system-*-link 2>/dev/null); do
        gen_num=$(echo "$link" | sed 's/.*system-\([0-9]*\)-link/\1/')
        target=$(readlink -f "$link")
        if [ -f "$target/kernel" ] && [ -f "$target/initrd" ]; then
            COUNT=$((COUNT + 1))
            GENERATIONS="$GENERATIONS $gen_num:$target"
            # Get NixOS version if available
            version=""
            if [ -f "$target/nixos-version" ]; then
                version=$(cat "$target/nixos-version")
            fi
            if [ $COUNT -eq 1 ]; then
                echo -e "  ${GREEN}[$COUNT] Generation $gen_num (current)${RESET} $version"
            else
                echo "  [$COUNT] Generation $gen_num $version"
            fi
            # Show max 10 entries
            if [ $COUNT -ge 10 ]; then
                break
            fi
        fi
    done
fi

if [ $COUNT -eq 0 ]; then
    echo "ERROR: No bootable generations found."
    umount "$MOUNT_POINT" 2>/dev/null
    exit 1
fi

echo ""
echo -e "  Default: 1 (timeout: ${TIMEOUT}s)"
echo ""

# Read selection with timeout
SELECTION=""
if [ $COUNT -gt 1 ]; then
    printf "  Select [1-%d]: " "$COUNT"
    # Read with timeout
    if read -t "$TIMEOUT" SELECTION 2>/dev/null; then
        true
    else
        SELECTION=""
    fi
fi

# Default to first entry
if [ -z "$SELECTION" ] || [ "$SELECTION" -lt 1 ] 2>/dev/null || [ "$SELECTION" -gt "$COUNT" ] 2>/dev/null; then
    SELECTION=1
fi

# Get selected generation
SELECTED=$(echo "$GENERATIONS" | tr ' ' '\n' | sed -n "${SELECTION}p")
GEN_NUM=$(echo "$SELECTED" | cut -d: -f1)
GEN_PATH=$(echo "$SELECTED" | cut -d: -f2)

echo ""
echo -e "  ${CYAN}Booting generation $GEN_NUM...${RESET}"
echo ""

# Read kernel params
KERNEL="$GEN_PATH/kernel"
INITRD="$GEN_PATH/initrd"
KERNEL_PARAMS=""
if [ -f "$GEN_PATH/kernel-params" ]; then
    KERNEL_PARAMS=$(cat "$GEN_PATH/kernel-params")
fi
# Append init path
KERNEL_PARAMS="$KERNEL_PARAMS init=$GEN_PATH/init"

# Unmount before kexec
umount "$MOUNT_POINT" 2>/dev/null || true

# kexec into selected generation
kexec --load "$KERNEL" --initrd="$INITRD" --command-line="$KERNEL_PARAMS"
kexec --exec
