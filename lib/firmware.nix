# Shared firmware population helpers used by sd-image, nvme-target, and the
# migration service.
{ lib, pkgs, config }:

let
  cfg = config.raspberry-pi-nix;
  kernel =
    "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
  initrd =
    "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
  kernel-params = pkgs.writeTextFile {
    name = "cmdline.txt";
    text = lib.strings.concatStringsSep " " config.boot.kernelParams + "\n";
  };
  firmwareSrc = "${pkgs.raspberrypifw}/share/raspberrypi/boot";
in {
  inherit kernel initrd kernel-params firmwareSrc;

  # Shell commands to populate a firmware directory (for sd-image and nvme-target).
  # `dest` is the shell variable/path where files should be copied.
  populateFirmwareDir = dest:
    let
      populate-kernel = if cfg.uboot.enable then ''
        cp ${cfg.uboot.package}/u-boot.bin ${dest}/u-boot-rpi-arm64.bin
      '' else ''
        cp "${kernel}" ${dest}/kernel.img
        cp "${initrd}" ${dest}/initrd
        cp "${kernel-params}" ${dest}/cmdline.txt
      '';
    in ''
      ${populate-kernel}
      cp -r ${firmwareSrc}/{start*.elf,*.dtb,bootcode.bin,fixup*.dat,overlays} ${dest}/
      cp ${config.hardware.raspberry-pi.config-output} ${dest}/config.txt
    '';
}
