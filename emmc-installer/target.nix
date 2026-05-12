# eMMC target system configuration.
# This defines the NixOS system that will be installed onto the eMMC.
# Users should import this and customize it (add users, services, etc.)
{ pkgs, lib, config, ... }:

let fw = import ../lib/firmware.nix { inherit lib pkgs config; };
in {
  config = {
    raspberry-pi-nix.board = lib.mkDefault "bcm2711";

    boot.initrd.availableKernelModules = [
      "mmc_block"
      "sdhci_iproc"
      "xhci_hcd"
      "xhci_pci"
      "usbhid"
      "usb_storage"
      "uas"
    ];

    # Ensure USB modules stay loaded after boot
    boot.kernelModules = [ "xhci_hcd" "xhci_pci" "usbhid" ];

    boot.kernelParams =
      lib.mkAfter [ "root=LABEL=NIXOS_EMMC" "rootfstype=ext4" "rootwait" ];

    fileSystems = {
      "/" = {
        device = "/dev/disk/by-label/NIXOS_EMMC";
        fsType = "ext4";
      };
      "/boot/firmware" = {
        device = "/dev/disk/by-label/FIRMWARE";
        fsType = "vfat";
        options = [ "noatime" "noauto" "x-systemd.automount" ];
      };
    };

    # The eMMC target builds the firmware partition contents as a derivation
    # so the installer can copy them.
    system.build.emmcFirmware = pkgs.runCommand "emmc-firmware" { } ''
      mkdir -p $out
      ${fw.populateFirmwareDir "$out"}
    '';
  };
}
