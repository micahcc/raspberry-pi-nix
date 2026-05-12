# NVMe installer module for the SD card image.
# This module configures the SD card system to include an install script
# that partitions and installs NixOS onto an NVMe drive.
{ config, lib, pkgs, ... }:

let
  # The target NixOS system closure that will be installed to NVMe
  targetToplevel =
    config.nvme-installer.targetSystem.config.system.build.toplevel;
  targetFirmware =
    config.nvme-installer.targetSystem.config.system.build.nvmeFirmware;

  install-script = pkgs.runCommand "install-nvme" {
    src = ./install-nvme.sh;
    nativeBuildInputs = [ pkgs.shellcheck ];
    targetToplevel = toString targetToplevel;
    targetFirmware = toString targetFirmware;
    firmwarePartitionSize = config.nvme-installer.firmwarePartitionSize;
    sfdisk = "${pkgs.util-linux}/bin/sfdisk";
    partprobe = "${pkgs.parted}/bin/partprobe";
    mkfsVfat = "${pkgs.dosfstools}/bin/mkfs.vfat";
    mkfsExt4 = "${pkgs.e2fsprogs}/bin/mkfs.ext4";
    nix = "${pkgs.nix}/bin/nix";
    nixEnv = "${pkgs.nix}/bin/nix-env";
    rpiEepromConfig = "${pkgs.raspberrypi-eeprom}/bin/rpi-eeprom-config";
  } ''
    shellcheck "$src"
    mkdir -p $out/bin
    substituteAll "$src" $out/bin/install-nvme
    chmod +x $out/bin/install-nvme
  '';
in {
  options.nvme-installer = {
    enable = lib.mkEnableOption "NVMe installer on the SD card image";

    targetSystem = lib.mkOption {
      type = lib.types.unspecified;
      description = ''
        The evaluated NixOS system configuration to install onto the NVMe.
        This should be the result of `nixpkgs.lib.nixosSystem { ... }`.
      '';
    };

    firmwarePartitionSize = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      description = ''
        Size of the firmware partition on the NVMe drive.
        This is larger than the SD card default (128MB) to provide room
        for firmware updates and multiple kernel versions.
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
    networking.interfaces.end0.ipv4.addresses = [{
      address = "192.168.1.100";
      prefixLength = 24;
    }];

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
