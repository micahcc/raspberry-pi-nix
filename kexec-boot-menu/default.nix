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
      default = 7;
      description = "Seconds to wait for user input before booting default generation";
    };
  };

  config = lib.mkIf cfg.enable {
    # Don't use u-boot
    raspberry-pi-nix.uboot.enable = lib.mkForce false;

    # Ensure NVMe, PCIe modules are in the initrd
    boot.initrd.availableKernelModules = [
      "nvme"
      "pcie_brcmstb"
    ];

    # Blacklist vc4 in initrd — when it loads, it destroys the firmware
    # framebuffer without creating a new one (no modeset = black screen).
    # This only affects auto-loading; vc4 loads normally in stage 2 via udev.
    boot.initrd.preDeviceCommands = lib.mkBefore ''
      mkdir -p /etc/modprobe.d
      echo "blacklist vc4" > /etc/modprobe.d/blacklist-vc4.conf
      echo "blacklist v3d" >> /etc/modprobe.d/blacklist-vc4.conf
    '';

    # fbcon=nodefer: force fbcon to claim the firmware framebuffer immediately.
    # console=tty1 at the END makes it the primary console (fbcon renders to HDMI).
    # init= points to the system profile (updated by switch-to-configuration boot).
    # This overrides the default init=/sbin/init which may be stale.
    boot.kernelParams = lib.mkAfter [
      "fbcon=nodefer"
      "console=tty1"
      "init=/nix/var/nix/profiles/system/init"
    ];

    # Force HDMI hotplug so Pi firmware initializes display regardless of HPD
    hardware.raspberry-pi.config.all.options.hdmi_force_hotplug = {
      enable = true;
      value = 1;
    };

    # Add kexec-tools to the initrd
    boot.initrd.extraUtilsCommands = ''
      copy_bin_and_libs ${pkgs.kexec-tools}/bin/kexec
    '';

    # Run the boot menu early in initrd
    boot.initrd.preLVMCommands = lib.mkBefore ''
      . ${menuScript}
    '';
  };
}
