#!/bin/sh
# NixOS kexec boot menu
# Runs in initrd preLVMCommands (devices available, root not yet mounted)
# Outputs to both HDMI (via /dev/tty0 + fbcon) and serial (/dev/ttyAMA0).

MOUNT_POINT="/boot-menu-root"
TIMEOUT=@timeout@
SERIAL_DEV="/dev/ttyAMA0"

# Output to both HDMI (tty0/fbcon) and serial
out() { echo "$@" > /dev/tty0 2>/dev/null; echo "$@" > $SERIAL_DEV 2>/dev/null; }
outn() { echo -n "$@" > /dev/tty0 2>/dev/null; echo -n "$@" > $SERIAL_DEV 2>/dev/null; }

# Skip menu if we already kexec'd into a selected generation
for o in $(cat /proc/cmdline); do
    case "$o" in
        bootmenu.skip=1) return 0 2>/dev/null || true ;;
    esac
done

# Wait for NVMe device to appear
outn "  Waiting for NVMe..."
attempts=0
while [ ! -b /dev/nvme0n1p2 ] && [ $attempts -lt 50 ]; do
    sleep 0.1
    attempts=$((attempts + 1))
done
if [ ! -b /dev/nvme0n1p2 ]; then
    out " not found after 5s, continuing default boot..."
    return 0 2>/dev/null || true
fi
out " found."

# Print banner
out ""
out "  ============================="
out "   NixOS Boot Menu"
out "  ============================="
out ""

# Mount NVMe root read-only
mkdir -p "$MOUNT_POINT"
if ! mount -o ro /dev/nvme0n1p2 "$MOUNT_POINT" 2>/dev/null; then
    out "  Could not mount /dev/nvme0n1p2, continuing default boot..."
    return 0 2>/dev/null || true
fi

PROFILES_DIR="$MOUNT_POINT/nix/var/nix/profiles"

if [ ! -d "$PROFILES_DIR" ]; then
    out "  Profiles directory not found, continuing default boot..."
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
            out "  [1] Generation $gen_num$version  <- default"
        else
            out "  [$count] Generation $gen_num$version"
        fi
    fi
done

if [ $count -eq 0 ]; then
    out "  No bootable generations found, continuing default boot..."
    umount "$MOUNT_POINT" 2>/dev/null || true
    return 0 2>/dev/null || true
fi

if [ $count -eq 1 ]; then
    out ""
    out "  Booting generation (only 1 available)..."
    umount "$MOUNT_POINT" 2>/dev/null || true
    return 0 2>/dev/null || true
fi

out ""
outn "  Select [1-$count] (default 1, timeout ${TIMEOUT}s): "

# Read with timeout from both serial and keyboard (console/tty)
selection=""
rm -f /tmp/.bootmenu-sel
(read -t "$TIMEOUT" s < $SERIAL_DEV 2>/dev/null && echo "$s" > /tmp/.bootmenu-sel) &
spid=$!
read -t "$TIMEOUT" selection 2>/dev/null || true
kill $spid 2>/dev/null || true
wait $spid 2>/dev/null || true
if [ -z "$selection" ] && [ -f /tmp/.bootmenu-sel ]; then
    selection=$(cat /tmp/.bootmenu-sel)
fi
rm -f /tmp/.bootmenu-sel

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

out ""

if [ "$selection" -eq 1 ]; then
    out "  Booting default generation..."
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

out "  Booting generation $gen_num..."

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
params="$params init=$init_path bootmenu.skip=1"

out "  Loading kernel..."
# Ensure serial console works after kexec (use real device name, not serial0 alias)
# Also add console=tty1 so fbcon renders to HDMI after kexec
params="$params console=ttyAMA0,115200n8 console=tty1"
kexec --load "$kernel" --initrd="$initrd" --command-line="$params"

umount "$MOUNT_POINT" 2>/dev/null || true

out "  Executing kexec..."
kexec --exec

# Should not reach here
out "  kexec failed! Continuing default boot..."
