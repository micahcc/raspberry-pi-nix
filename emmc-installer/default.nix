# Builds the flash-emmc script as a standalone package.
# Usage: mkFlashEmmc { inherit pkgs; emmcImage = <emmc-image derivation>; }
{ pkgs, emmcImage, compressed ? true }:

let
  imagePath = if compressed then
    "${emmcImage}/emmc-image/nixos-emmc.img.zst"
  else
    "${emmcImage}/emmc-image/nixos-emmc.img";
in pkgs.runCommand "flash-emmc" {
  src = ./flash-emmc.sh;
  nativeBuildInputs = [ pkgs.shellcheck ];
  rpiboot = "${pkgs.rpiboot}/bin/rpiboot";
  zstd = "${pkgs.zstd}/bin/zstd";
  lsusb = "${pkgs.usbutils}/bin/lsusb";
  image = imagePath;
} ''
  shellcheck "$src"
  mkdir -p $out/bin
  substituteAll "$src" $out/bin/flash-emmc
  chmod +x $out/bin/flash-emmc
''
