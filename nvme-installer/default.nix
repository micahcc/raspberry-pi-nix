# NVMe installer module for the SD card image.
# This module configures the SD card system to include an install script
# that partitions and installs NixOS onto an NVMe drive.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # The target NixOS system closure that will be installed to NVMe
  targetToplevel = config.nvme-installer.targetSystem.config.system.build.toplevel;
  targetFirmware = config.nvme-installer.targetSystem.config.system.build.nvmeFirmware;

  install-script = pkgs.writeShellScriptBin "install-nvme" ''
    set -euo pipefail

    NVME_DEV="''${1:-/dev/nvme0n1}"
    TARGET_TOPLEVEL="${targetToplevel}"
    TARGET_FIRMWARE="${targetFirmware}"

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
    read -p "Continue? [y/N] " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo "Aborted."
      exit 0
    fi

    echo ""
    echo ">>> Unmounting any existing partitions on $NVME_DEV..."
    findmnt -rno SOURCE,TARGET | grep "^''${NVME_DEV}" | while read -r src mnt; do
      echo "    Unmounting $src ($mnt)"
      umount "$mnt" || umount -l "$mnt"
    done || true

    echo ">>> Partitioning $NVME_DEV..."
    ${pkgs.util-linux}/bin/sfdisk "$NVME_DEV" <<EOF
    label: dos

    size=512M, type=b
    type=83
    EOF

    sleep 1
    ${pkgs.parted}/bin/partprobe "$NVME_DEV"
    sleep 1

    FIRMWARE_PART="''${NVME_DEV}p1"
    ROOT_PART="''${NVME_DEV}p2"

    echo ">>> Formatting firmware partition ($FIRMWARE_PART) as FAT32..."
    ${pkgs.dosfstools}/bin/mkfs.vfat -F 32 -n FIRMWARE "$FIRMWARE_PART"

    echo ">>> Formatting root partition ($ROOT_PART) as ext4..."
    ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F -L NIXOS_NVME "$ROOT_PART"

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

    echo ">>> Copying NixOS closure to NVMe (this may take a while)..."
    mkdir -p "$MOUNT_ROOT/nix/store"

    # Copy all store paths needed by the target system
    ${pkgs.nix}/bin/nix --extra-experimental-features nix-command copy --no-check-sigs --to "local?root=$MOUNT_ROOT" "$TARGET_TOPLEVEL"

    echo ">>> Setting up system profile..."
    mkdir -p "$MOUNT_ROOT/nix/var/nix/profiles"
    ${pkgs.nix}/bin/nix-env --store "local?root=$MOUNT_ROOT" \
      --profile "$MOUNT_ROOT/nix/var/nix/profiles/system" \
      --set "$TARGET_TOPLEVEL"

    echo ">>> Installing /sbin/init..."
    mkdir -p "$MOUNT_ROOT/sbin"
    ln -sf /nix/var/nix/profiles/system/init "$MOUNT_ROOT/sbin/init"

    echo ">>> Creating /etc/NIXOS marker..."
    mkdir -p "$MOUNT_ROOT/etc"
    touch "$MOUNT_ROOT/etc/NIXOS"

    echo ">>> Populating firmware partition..."
    cp -r "$TARGET_FIRMWARE"/* "$MOUNT_ROOT/boot/firmware/"

    echo ">>> Syncing..."
    sync

    echo ">>> Configuring EEPROM for NVMe PCIe probe..."
    # Set PCIE_PROBE=1 for non-HAT+ NVMe adapters
    # Keep default boot order (SD, USB, NVMe)
    EEPROM_CONFIG=$(${pkgs.raspberrypi-eeprom}/bin/rpi-eeprom-config 2>/dev/null || true)
    if [ -n "$EEPROM_CONFIG" ]; then
      TMPCONF=$(mktemp)
      echo "$EEPROM_CONFIG" | sed \
        -e 's/^PCIE_PROBE=.*/PCIE_PROBE=1/' \
        > "$TMPCONF"
      # Add PCIE_PROBE if it doesn't exist
      grep -q '^PCIE_PROBE=' "$TMPCONF" || echo "PCIE_PROBE=1" >> "$TMPCONF"
      ${pkgs.raspberrypi-eeprom}/bin/rpi-eeprom-config --apply "$TMPCONF" || {
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
  '';
in
{
  options.nvme-installer = {
    enable = lib.mkEnableOption "NVMe installer on the SD card image";

    targetSystem = lib.mkOption {
      type = lib.types.unspecified;
      description = ''
        The evaluated NixOS system configuration to install onto the NVMe.
        This should be the result of `nixpkgs.lib.nixosSystem { ... }`.
      '';
    };
  };

  config = lib.mkIf config.nvme-installer.enable {
    environment.systemPackages = [
      install-script
      pkgs.parted
      pkgs.dosfstools
      pkgs.e2fsprogs
      pkgs.util-linux
      pkgs.raspberrypi-eeprom
      pkgs.nix
      pkgs.vim
    ];

    # Auto-login as root (no password prompt)
    services.getty.autologinUser = "root";
    users.users.root.initialPassword = "nixos";

    # Allow root SSH with password
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "yes";
        PasswordAuthentication = true;
      };
    };

    # Static IP for reliable SSH access
    networking.interfaces.end0.ipv4.addresses = [
      {
        address = "192.168.1.100";
        prefixLength = 24;
      }
    ];

    # Show install instructions on login
    environment.interactiveShellInit = ''
      echo ""
      echo "  =========================================="
      echo "   NixOS NVMe Installer for Raspberry Pi 5"
      echo "  =========================================="
      echo ""
      echo "  SSH access:"
      echo "    ssh root@192.168.1.100"
      echo "    password: nixos"
      echo ""
      echo "  To install NixOS onto the NVMe drive, run:"
      echo ""
      echo "    install-nvme"
      echo ""
      echo "  (optionally specify a device: install-nvme /dev/nvme0n1)"
      echo ""
    '';

    # Ensure NVMe is available in the installer
    boot.initrd.availableKernelModules = [ "nvme" ];
  };
}
