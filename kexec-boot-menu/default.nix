# Kexec boot menu module for Raspberry Pi.
# Adds a boot menu to the NixOS initrd that presents available generations
# and can kexec into a different one before continuing boot.
# This works without u-boot — Pi firmware loads kernel + initrd directly.
{ config, lib, pkgs, ... }:

let
  cfg = config.kexec-boot-menu;

  menuScript = pkgs.replaceVars ./menu.sh {
    timeout = toString cfg.timeout;
  };

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

    # Ensure NVMe and PCIe modules are in the initrd
    boot.initrd.availableKernelModules = [
      "nvme"
      "pcie_brcmstb"
    ];

    # Add kexec-tools to the initrd
    boot.initrd.extraUtilsCommands = ''
      copy_bin_and_libs ${pkgs.kexec-tools}/bin/kexec
    '';

    # Run the boot menu early in initrd, after devices are available
    boot.initrd.preLVMCommands = lib.mkBefore ''
      . ${menuScript}
    '';
  };
}
