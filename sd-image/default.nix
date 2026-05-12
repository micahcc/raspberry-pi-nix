{ config, lib, pkgs, ... }:

let
  fw = import ../lib/firmware.nix { inherit lib pkgs config; };
  cfg = config.raspberry-pi-nix;
in {
  imports = [ ./sd-image.nix ];

  config = {
    boot.loader.grub.enable = false;

    boot.consoleLogLevel = lib.mkDefault 7;

    boot.kernelParams = [
      # This is ugly and fragile, but the sdImage image has an msdos
      # table, so the partition table id is a 1-indexed hex
      # number. So, we drop the hex prefix and stick on a "02" to
      # refer to the root partition.
      "root=PARTUUID=${
        lib.strings.removePrefix "0x" config.sdImage.firmwarePartitionID
      }-02"
      "rootfstype=ext4"
      "fsck.repair=yes"
      "rootwait"
    ];

    sdImage = {
      populateFirmwareCommands = fw.populateFirmwareDir "firmware";
      populateRootCommands = if cfg.uboot.enable then ''
        mkdir -p ./files/boot
        ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
      '' else ''
        mkdir -p ./files/sbin
        content="$(
          echo "#!${pkgs.bash}/bin/bash"
          echo "exec ${config.system.build.toplevel}/init"
        )"
        echo "$content" > ./files/sbin/init
        chmod 744 ./files/sbin/init
      '';
    };
  };
}
