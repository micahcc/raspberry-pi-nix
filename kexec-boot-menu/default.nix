# Kexec boot menu module for Raspberry Pi.
# Adds a boot menu to the NixOS initrd that presents available generations
# and can kexec into a different one before continuing boot.
# This works without u-boot — Pi firmware loads kernel + initrd directly.
{ config, lib, pkgs, ... }:

let
  cfg = config.kexec-boot-menu;

  menuScript = pkgs.writeScript "boot-menu" ''
    #!/bin/sh
    # NixOS kexec boot menu
    # Runs early in initrd stage 1

    MOUNT_POINT="/boot-menu-root"
    TIMEOUT=${toString cfg.timeout}

    echo ""
    echo "  NixOS Boot Menu"
    echo "  ==============================="
    echo ""

    # Mount NVMe root read-only
    mkdir -p "$MOUNT_POINT"
    if ! mount -o ro /dev/disk/by-label/NIXOS_NVME "$MOUNT_POINT" 2>/dev/null; then
        echo "  Could not mount root, continuing default boot..."
        return 0 2>/dev/null || exit 0
    fi

    PROFILES_DIR="$MOUNT_POINT/nix/var/nix/profiles"

    # Collect generations (most recent first)
    count=0
    for link in $(ls -1t "$PROFILES_DIR"/system-*-link 2>/dev/null); do
        gen_num=$(echo "$link" | sed 's/.*system-\([0-9]*\)-link/\1/')
        target=$(readlink -f "$link")

        if [ -f "$target/kernel" ] && [ -f "$target/initrd" ]; then
            count=$((count + 1))
            eval "GEN_$count=$gen_num"
            eval "PATH_$count=$target"

            version=""
            if [ -f "$target/nixos-version" ]; then
                version=" ($(cat "$target/nixos-version"))"
            fi

            if [ $count -eq 1 ]; then
                echo "  [1] Generation $gen_num$version  <- default"
            else
                echo "  [$count] Generation $gen_num$version"
            fi

            [ $count -ge 10 ] && break
        fi
    done

    if [ $count -eq 0 ]; then
        echo "  No bootable generations found, continuing default boot..."
        umount "$MOUNT_POINT" 2>/dev/null
        return 0 2>/dev/null || exit 0
    fi

    echo ""
    printf "  Select [1-%d] (default 1, timeout %ds): " "$count" "$TIMEOUT"

    # Read with timeout
    selection=""
    read -t "$TIMEOUT" selection 2>/dev/null || true

    # Validate selection
    if [ -z "$selection" ] || ! [ "$selection" -ge 1 ] 2>/dev/null || ! [ "$selection" -le "$count" ] 2>/dev/null; then
        selection=1
    fi

    eval "gen_num=\$GEN_$selection"
    eval "gen_path=\$PATH_$selection"

    echo ""
    echo "  Booting generation $gen_num..."
    echo ""

    if [ "$selection" -eq 1 ]; then
        # Default generation — just continue normal boot
        umount "$MOUNT_POINT" 2>/dev/null
        return 0 2>/dev/null || exit 0
    fi

    # Non-default: kexec into selected generation
    kernel="$gen_path/kernel"
    initrd="$gen_path/initrd"
    params=""
    if [ -f "$gen_path/kernel-params" ]; then
        params=$(cat "$gen_path/kernel-params")
    fi
    params="$params init=$gen_path/init"

    echo "  Loading kernel from $kernel..."
    kexec --load "$kernel" --initrd="$initrd" --command-line="$params"

    umount "$MOUNT_POINT" 2>/dev/null

    echo "  Executing kexec..."
    kexec --exec

    # Should not reach here
    echo "  kexec failed!"
    exit 1
  '';

in {
  options.kexec-boot-menu = {
    enable = lib.mkEnableOption "kexec-based boot menu for NixOS generation selection";

    timeout = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Seconds to wait for user input before booting default generation";
    };
  };

  config = lib.mkIf cfg.enable {
    # Don't use u-boot
    raspberry-pi-nix.uboot.enable = lib.mkForce false;

    # Include kexec-tools and necessary modules in the initrd
    boot.initrd.availableKernelModules = [
      "nvme"
      "pcie_brcmstb"
    ];

    boot.initrd.extraUtilsCommands = ''
      copy_bin_and_libs ${pkgs.kexec-tools}/bin/kexec
    '';

    # Run the boot menu script early in stage 1 (initrd)
    boot.initrd.preLVMCommands = ''
      . ${menuScript}
    '';
  };
}
