# Builds a raw flashable eMMC disk image from a target NixOS configuration.
# The image is MBR partitioned with a FAT32 firmware partition and ext4 root.
# It can be flashed directly via rpi-imager or dd.
{ modulesPath, config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types;
  fw = import ../lib/firmware.nix { inherit lib pkgs config; };

  rootfsImage = pkgs.callPackage "${modulesPath}/../lib/make-ext4-fs.nix" {
    storePaths = [ config.system.build.toplevel ];
    compressImage = true;
    populateImageCommands = ''
      mkdir -p ./files/sbin
      content="$(
        echo "#!${pkgs.bash}/bin/bash"
        echo "exec ${config.system.build.toplevel}/init"
      )"
      echo "$content" > ./files/sbin/init
      chmod 744 ./files/sbin/init

      mkdir -p ./files/etc
      touch ./files/etc/NIXOS

      mkdir -p ./files/nix/var/nix/profiles
    '';
    volumeLabel = "NIXOS_EMMC";
  };
in {
  options.emmcImage = {
    firmwareSize = mkOption {
      type = types.int;
      default = 512;
      description = "Size of the firmware partition in megabytes.";
    };

    firmwarePartitionOffset = mkOption {
      type = types.int;
      default = 8;
      description = "Gap before the first partition, in MiB.";
    };

    compressImage = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to compress the final image with zstd.";
    };
  };

  config = {
    system.build.emmcImage = pkgs.callPackage ({ stdenv, dosfstools, e2fsprogs
      , mtools, libfaketime, util-linux, zstd }:
      stdenv.mkDerivation {
        name = "nixos-emmc-image-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}.img";

        nativeBuildInputs =
          [ dosfstools e2fsprogs mtools libfaketime util-linux zstd ];

        inherit (config.emmcImage) compressImage;

        buildCommand = ''
          mkdir -p $out/nix-support $out/emmc-image
          export img=$out/emmc-image/nixos-emmc.img

          echo "${pkgs.stdenv.buildPlatform.system}" > $out/nix-support/system
          if test -n "$compressImage"; then
            echo "file emmc-image $img.zst" >> $out/nix-support/hydra-build-products
          else
            echo "file emmc-image $img" >> $out/nix-support/hydra-build-products
          fi

          echo "Decompressing rootfs image"
          zstd -d --no-progress "${rootfsImage}" -o ./root-fs.img

          gap=${toString config.emmcImage.firmwarePartitionOffset}

          rootSizeBlocks=$(du -B 512 --apparent-size ./root-fs.img | awk '{ print $1 }')
          firmwareSizeBlocks=$((${toString config.emmcImage.firmwareSize} * 1024 * 1024 / 512))
          imageSize=$((rootSizeBlocks * 512 + firmwareSizeBlocks * 512 + gap * 1024 * 1024))
          truncate -s $imageSize $img

          sfdisk $img <<EOF
              label: dos

              start=''${gap}M, size=$firmwareSizeBlocks, type=b
              start=$((gap + ${toString config.emmcImage.firmwareSize}))M, type=83
          EOF

          # Copy rootfs into the image
          eval $(partx $img -o START,SECTORS --nr 2 --pairs)
          dd conv=notrunc if=./root-fs.img of=$img seek=$START count=$SECTORS

          # Create and populate firmware partition
          eval $(partx $img -o START,SECTORS --nr 1 --pairs)
          truncate -s $((SECTORS * 512)) firmware_part.img
          faketime "1970-01-01 00:00:00" mkfs.vfat -F 32 -n FIRMWARE firmware_part.img

          mkdir firmware
          ${fw.populateFirmwareDir "firmware"}

          (cd firmware; mcopy -psvm -i ../firmware_part.img ./* ::)
          fsck.vfat -vn firmware_part.img
          dd conv=notrunc if=firmware_part.img of=$img seek=$START count=$SECTORS

          if test -n "$compressImage"; then
              zstd -T$NIX_BUILD_CORES --rm $img
          fi
        '';
      }) { };
  };
}
