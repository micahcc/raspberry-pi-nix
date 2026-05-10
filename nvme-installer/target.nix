# NVMe target system configuration.
# This defines the NixOS system that will be installed onto the NVMe drive.
# Users should import this and customize it (add users, services, etc.)
{ pkgs, lib, config, ... }:

let
  cfg = config.raspberry-pi-nix;
  kernel = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
  initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
  kernel-params = pkgs.writeTextFile {
    name = "cmdline.txt";
    text = ''
      ${lib.strings.concatStringsSep " " config.boot.kernelParams}
    '';
  };
in
{
  config = {
    raspberry-pi-nix.board = lib.mkDefault "bcm2712";
    raspberry-pi-nix.kernel-version = lib.mkDefault "v6_12_87";

    boot.initrd.availableKernelModules = [
      "nvme"
      "pcie_brcmstb"
      "xhci_hcd"
      "xhci_pci"
      "usbhid"
      "usb_storage"
      "uas"
    ];

    # Ensure USB modules stay loaded after boot
    boot.kernelModules = [
      "xhci_hcd"
      "xhci_pci"
      "usbhid"
    ];

    boot.kernelParams = lib.mkAfter [
      "root=LABEL=NIXOS_NVME"
      "rootfstype=ext4"
      "rootwait"
      # Override firmware's pci=pcie_bus_safe which prevents MSI-X
      # allocation on RP1, breaking USB and Ethernet
      "pci=pcie_bus_perf"
    ];

    fileSystems = {
      "/" = {
        device = "/dev/disk/by-label/NIXOS_NVME";
        fsType = "ext4";
      };
      "/boot/firmware" = {
        device = "/dev/disk/by-label/FIRMWARE";
        fsType = "vfat";
        options = [ "noatime" "noauto" "x-systemd.automount" ];
      };
    };

    # The NVMe target builds the firmware partition contents as a derivation
    # so the installer can copy them.
    system.build.nvmeFirmware = pkgs.runCommand "nvme-firmware" { } ''
      mkdir -p $out

      # Kernel and initrd
      cp "${kernel}" $out/kernel.img
      cp "${initrd}" $out/initrd
      cp "${kernel-params}" $out/cmdline.txt

      # RPi firmware files
      cp -r ${pkgs.raspberrypifw}/share/raspberrypi/boot/{start*.elf,*.dtb,bootcode.bin,fixup*.dat} $out/
      cp -r ${pkgs.raspberrypifw}/share/raspberrypi/boot/overlays $out/

      # config.txt
      cp ${config.hardware.raspberry-pi.config-output} $out/config.txt
    '';
  };
}
