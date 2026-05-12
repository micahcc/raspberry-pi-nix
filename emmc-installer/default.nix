# eMMC installer module for the SD card image.
# This module configures the SD card system to include an install script
# that partitions and installs NixOS onto the onboard eMMC (CM4/CM5).
{ config, lib, pkgs, ... }:

let
  targetToplevel =
    config.emmc-installer.targetSystem.config.system.build.toplevel;
  targetFirmware =
    config.emmc-installer.targetSystem.config.system.build.emmcFirmware;

  install-script = pkgs.runCommand "install-emmc" {
    src = ./install-emmc.sh;
    nativeBuildInputs = [ pkgs.shellcheck ];
    targetToplevel = toString targetToplevel;
    targetFirmware = toString targetFirmware;
    firmwarePartitionSize = config.emmc-installer.firmwarePartitionSize;
    sfdisk = "${pkgs.util-linux}/bin/sfdisk";
    partprobe = "${pkgs.parted}/bin/partprobe";
    mkfsVfat = "${pkgs.dosfstools}/bin/mkfs.vfat";
    mkfsExt4 = "${pkgs.e2fsprogs}/bin/mkfs.ext4";
    nix = "${pkgs.nix}/bin/nix";
    nixEnv = "${pkgs.nix}/bin/nix-env";
  } ''
    shellcheck "$src"
    mkdir -p $out/bin
    substituteAll "$src" $out/bin/install-emmc
    chmod +x $out/bin/install-emmc
  '';
in {
  options.emmc-installer = {
    enable = lib.mkEnableOption "eMMC installer on the SD card image";

    targetSystem = lib.mkOption {
      type = lib.types.unspecified;
      description = ''
        The evaluated NixOS system configuration to install onto the eMMC.
        This should be the result of `nixpkgs.lib.nixosSystem { ... }`.
      '';
    };

    firmwarePartitionSize = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      description = ''
        Size of the firmware partition on the eMMC.
      '';
    };
  };

  config = lib.mkIf config.emmc-installer.enable {
    environment.systemPackages = [
      install-script
      pkgs.parted
      pkgs.dosfstools
      pkgs.e2fsprogs
      pkgs.util-linux
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
      echo "   NixOS eMMC Installer for Raspberry Pi"
      echo "  =========================================="
      echo ""
      echo "  SSH access:"
      echo "    ssh root@192.168.1.100"
      echo "    password: nixos"
      echo ""
      echo "  To install NixOS onto the eMMC, run:"
      echo ""
      echo "    install-emmc"
      echo ""
      echo "  (optionally specify a device: install-emmc /dev/mmcblk0)"
      echo ""
    '';

    # Ensure mmc is available in the installer
    boot.initrd.availableKernelModules = [ "mmc_block" "sdhci_iproc" ];
  };
}
