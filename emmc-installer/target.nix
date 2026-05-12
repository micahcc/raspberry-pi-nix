# eMMC target system configuration.
# This defines the NixOS system that will be installed onto the eMMC.
# Users should import this and customize it (add users, services, etc.)
{ pkgs, lib, config, ... }:

{
  imports = [ ./emmc-image.nix ];

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

    # Expand root partition on first boot (image is sized to fit contents)
    boot.postBootCommands = ''
      if [ -f /nix-path-registration ]; then
        set -euo pipefail
        rootPart=$(${pkgs.util-linux}/bin/findmnt -n -o SOURCE /)
        bootDevice=$(lsblk -npo PKNAME $rootPart)
        partNum=$(lsblk -npo PARTN $rootPart)

        echo ",+," | sfdisk -N$partNum --no-reread $bootDevice
        ${pkgs.parted}/bin/partprobe
        ${pkgs.e2fsprogs}/bin/resize2fs $rootPart

        ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration
        touch /etc/NIXOS
        ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system

        rm -f /nix-path-registration
      fi
    '';
  };
}
