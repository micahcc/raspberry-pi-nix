#!/bin/sh
# NixOS kexec boot menu
# Runs in initrd preLVMCommands (devices available, root not yet mounted)

MOUNT_POINT="/boot-menu-root"
TIMEOUT=@timeout@

echo ""
echo "  ============================="
echo "   NixOS Boot Menu"
echo "  ============================="
echo ""

# Wait for NVMe device to appear
echo -n "  Waiting for NVMe..."
attempts=0
while [ ! -b /dev/nvme0n1p2 ] && [ $attempts -lt 50 ]; do
    sleep 0.1
    attempts=$((attempts + 1))
done
if [ -b /dev/nvme0n1p2 ]; then
    echo " found."
else
    echo " not found after 5s, continuing default boot..."
    return 0 2>/dev/null || true
fi

# Mount NVMe root read-only
mkdir -p "$MOUNT_POINT"
if ! mount -o ro /dev/nvme0n1p2 "$MOUNT_POINT" 2>/dev/null; then
    echo "  Could not mount /dev/nvme0n1p2, continuing default boot..."
    return 0 2>/dev/null || true
fi

PROFILES_DIR="$MOUNT_POINT/nix/var/nix/profiles"

if [ ! -d "$PROFILES_DIR" ]; then
    echo "  Profiles directory not found, continuing default boot..."
    umount "$MOUNT_POINT" 2>/dev/null || true
    return 0 2>/dev/null || true
fi

# Collect generations (highest number = most recent)
# Uses shell glob + [ -L ] instead of ls, because busybox ls fails on
# dangling symlinks (targets point to /nix/store which isn't at that path
# in the initrd).
count=0
gen_nums=""
gen_paths=""
found_links=""
for f in "$PROFILES_DIR"/system-*-link; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    num=$(echo "$f" | sed 's/.*system-\([0-9]*\)-link/\1/')
    found_links="$found_links $num"
done
found_links=$(echo $found_links | tr ' ' '\n' | sort -rn | head -10 | tr '\n' ' ')
for gen_num in $found_links; do
    link="$PROFILES_DIR/system-${gen_num}-link"
    # Resolve symlink target
    target=$(readlink "$link" 2>/dev/null)
    # Absolute paths need mount point prefix to be accessible
    case "$target" in
        /*) target="${MOUNT_POINT}${target}" ;;
        *) target="$PROFILES_DIR/$target" ;;
    esac

    # Use -L (is symlink) since kernel/initrd are symlinks to absolute
    # /nix/store paths that can't be followed without the mount prefix
    if [ -L "$target/kernel" ] && [ -L "$target/initrd" ]; then
        count=$((count + 1))
        gen_nums="$gen_nums $gen_num"
        gen_paths="$gen_paths $target"

        version=""
        if [ -f "$target/nixos-version" ]; then
            version=" ($(cat "$target/nixos-version"))"
        fi

        if [ $count -eq 1 ]; then
            echo "  [1] Generation $gen_num$version  <- default"
        else
            echo "  [$count] Generation $gen_num$version"
        fi
    fi
done

if [ $count -eq 0 ]; then
    echo "  No bootable generations found, continuing default boot..."
    umount "$MOUNT_POINT" 2>/dev/null || true
    return 0 2>/dev/null || true
fi

if [ $count -eq 1 ]; then
    echo ""
    echo "  Booting generation (only 1 available)..."
    umount "$MOUNT_POINT" 2>/dev/null || true
    return 0 2>/dev/null || true
fi

echo ""
echo -n "  Select [1-$count] (default 1, timeout ${TIMEOUT}s): "

# Read with timeout
selection=""
read -t "$TIMEOUT" selection 2>/dev/null || true

# Validate selection
case "$selection" in
    [0-9]|[0-9][0-9])
        if [ "$selection" -lt 1 ] || [ "$selection" -gt "$count" ]; then
            selection=1
        fi
        ;;
    *)
        selection=1
        ;;
esac

echo ""

if [ "$selection" -eq 1 ]; then
    echo "  Booting default generation..."
    umount "$MOUNT_POINT" 2>/dev/null || true
    return 0 2>/dev/null || true
fi

# Get selected generation path
i=0
gen_path=""
gen_num=""
for p in $gen_paths; do
    i=$((i + 1))
    if [ $i -eq "$selection" ]; then
        gen_path="$p"
        break
    fi
done
i=0
for n in $gen_nums; do
    i=$((i + 1))
    if [ $i -eq "$selection" ]; then
        gen_num="$n"
        break
    fi
done

echo "  Booting generation $gen_num..."

# Resolve kernel/initrd symlinks — they point to absolute /nix/store paths
# that need the mount point prefix to be accessible
kernel=$(readlink "$gen_path/kernel")
case "$kernel" in
    /*) kernel="${MOUNT_POINT}${kernel}" ;;
    *) kernel="$gen_path/$kernel" ;;
esac
initrd=$(readlink "$gen_path/initrd")
case "$initrd" in
    /*) initrd="${MOUNT_POINT}${initrd}" ;;
    *) initrd="$gen_path/$initrd" ;;
esac
params=""
if [ -f "$gen_path/kernel-params" ] || [ -L "$gen_path/kernel-params" ]; then
    kp="$gen_path/kernel-params"
    # resolve if symlink
    if [ -L "$kp" ]; then
        real_kp=$(readlink "$kp")
        case "$real_kp" in
            /*) kp="${MOUNT_POINT}${real_kp}" ;;
            *) kp="$gen_path/$real_kp" ;;
        esac
    fi
    params=$(cat "$kp")
fi
# init= must use the real path (without mount prefix) since it's used
# after kexec when the actual root filesystem is mounted
real_gen_path=$(echo "$gen_path" | sed "s|^${MOUNT_POINT}||")
init_path="$real_gen_path/init"
# But init might itself be a symlink; resolve it
if [ -L "$gen_path/init" ]; then
    init_path=$(readlink "$gen_path/init")
fi
params="$params init=$init_path"

echo "  Loading kernel..."
kexec --load "$kernel" --initrd="$initrd" --command-line="$params"

umount "$MOUNT_POINT" 2>/dev/null || true

echo "  Executing kexec..."
kexec --exec

# Should not reach here
echo "  kexec failed! Continuing default boot..."
