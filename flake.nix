{
  description = "raspberry-pi nixos configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    rpi-linux-stable-src = {
      flake = false;
      url = "github:raspberrypi/linux/stable_20241008";
    };
    rpi-linux-6_6_78-src = {
      flake = false;
      url = "github:raspberrypi/linux/rpi-6.6.y";
    };
    rpi-linux-6_12_87-src = {
      flake = false;
      url = "github:raspberrypi/linux/rpi-6.12.y";
    };
    rpi-linux-6_18_28-src = {
      flake = false;
      url = "github:raspberrypi/linux/rpi-6.18.y";
    };
    rpi-firmware-src = {
      flake = false;
      url = "github:raspberrypi/firmware/1.20241008";
    };
    rpi-firmware-nonfree-src = {
      flake = false;
      url = "github:RPi-Distro/firmware-nonfree/bookworm";
    };
    rpi-bluez-firmware-src = {
      flake = false;
      url = "github:RPi-Distro/bluez-firmware/bookworm";
    };
    rpicam-apps-src = {
      flake = false;
      url = "github:raspberrypi/rpicam-apps/v1.5.2";
    };
    libcamera-src = {
      flake = false;
      url =
        "github:raspberrypi/libcamera/69a894c4adad524d3063dd027f5c4774485cf9db"; # v0.3.1+rpt20240906
    };
    libpisp-src = {
      flake = false;
      url = "github:raspberrypi/libpisp/v1.0.7";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = srcs@{ self, ... }:
    let
      pinned = import srcs.nixpkgs {
        system = "aarch64-linux";
        overlays = with self.overlays; [ core libcamera ];
      };
    in {
      overlays = {
        core = import ./overlays (builtins.removeAttrs srcs [ "self" ]);
        libcamera = import ./overlays/libcamera.nix
          (builtins.removeAttrs srcs [ "self" ]);
      };
      nixosModules = {
        raspberry-pi = import ./rpi {
          inherit pinned;
          core-overlay = self.overlays.core;
          libcamera-overlay = self.overlays.libcamera;
        };
        default = self.nixosModules.raspberry-pi;
        sd-image = import ./sd-image;
        nvme-installer = import ./nvme-installer;
        nvme-target = import ./nvme-installer/target.nix;
        emmc-target = import ./emmc-installer/target.nix;
        kexec-boot-menu = import ./kexec-boot-menu;
      };
      nixosConfigurations = {
        rpi-example = srcs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            self.nixosModules.raspberry-pi
            self.nixosModules.sd-image
            ./example
          ];
        };

        # The NVMe target system (what gets installed on the NVMe)
        nvme-target = srcs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            self.nixosModules.raspberry-pi
            self.nixosModules.nvme-target
            ./nvme-installer/example.nix
          ];
        };

        # The SD card installer image (boots from SD, installs to NVMe)
        nvme-installer = srcs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            self.nixosModules.raspberry-pi
            self.nixosModules.sd-image
            self.nixosModules.nvme-installer
            ({ lib, ... }: {
              raspberry-pi-nix.board = "bcm2712";
              # Use the same kernel as the target system (unless overridden)
              raspberry-pi-nix.kernel-version = lib.mkDefault
                self.nixosConfigurations.nvme-target.config.raspberry-pi-nix.kernel-version;
              networking.hostName = "rpi5-installer";
              networking.useDHCP = true;
              services.openssh.enable = true;

              hardware.raspberry-pi.config.all.options = {
                # Without this, HDMI output may not activate if the
                # display isn't detected during early firmware init.
                hdmi_force_hotplug = {
                  enable = true;
                  value = 1;
                };
                # Without this, the Pi refuses to boot from USB claiming
                # insufficient power, even with a capable PSU that doesn't
                # negotiate via USB-PD.
                usb_max_current_enable = {
                  enable = true;
                  value = 1;
                };
              };
              nvme-installer = {
                enable = true;
                targetSystem = self.nixosConfigurations.nvme-target;
              };
            })
          ];
        };

        # The eMMC target system (what gets flashed onto the eMMC)
        emmc-target = srcs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            self.nixosModules.raspberry-pi
            self.nixosModules.emmc-target
            ./emmc-installer/example.nix
          ];
        };

      };
      # Example: building nvmeInstallerSdImage independently from sdImage.
      #   nix build .#raspberrypis.rpi5.nvmeInstallerSdImage
      #   nix build .#raspberrypis.rpi5.sdImage
      raspberrypis.rpi5 = {
        sdImage =
          self.nixosConfigurations.rpi-example.config.system.build.sdImage;
        nvmeInstallerSdImage =
          self.nixosConfigurations.nvme-installer.config.system.build.sdImage;
      };
      raspberrypis.cm4 = {
        emmcImage =
          self.nixosConfigurations.emmc-target.config.system.build.emmcImage;
      };

      formatter.x86_64-linux = (srcs.treefmt-nix.lib.evalModule
        (import srcs.nixpkgs { system = "x86_64-linux"; })
        ./treefmt.nix).config.build.wrapper;
      formatter.aarch64-linux = (srcs.treefmt-nix.lib.evalModule pinned
        ./treefmt.nix).config.build.wrapper;

      checks.aarch64-linux = self.packages.aarch64-linux;
      packages.aarch64-linux = with pinned.lib;
        let
          kernels = foldlAttrs f { } pinned.rpi-kernels;
          f = acc: kernel-version: board-attr-set:
            foldlAttrs (acc: board-version: drv:
              acc // {
                "linux-${kernel-version}-${board-version}" = drv;
              }) acc board-attr-set;
        in {
          example-sd-image =
            self.nixosConfigurations.rpi-example.config.system.build.sdImage;
          nvme-installer-sd-image =
            self.nixosConfigurations.nvme-installer.config.system.build.sdImage;
          emmc-image =
            self.nixosConfigurations.emmc-target.config.system.build.emmcImage;
          flash-emmc = import ./emmc-installer {
            pkgs = pinned;
            emmcImage =
              self.nixosConfigurations.emmc-target.config.system.build.emmcImage;
          };
          firmware = pinned.raspberrypifw;
          libcamera = pinned.libcamera;
          wireless-firmware = pinned.raspberrypiWirelessFirmware;
          uboot-rpi-arm64 = pinned.uboot-rpi-arm64;
        } // kernels;

      # Cross-compilation support: build aarch64 images from x86_64 machines.
      packages.x86_64-linux = let
        pkgsCross = import srcs.nixpkgs {
          system = "x86_64-linux";
          crossSystem.system = "aarch64-linux";
        };
      in {
        example-sd-image =
          self.nixosConfigurations.rpi-example.config.system.build.sdImage;
        nvme-installer-sd-image =
          self.nixosConfigurations.nvme-installer.config.system.build.sdImage;
        emmc-image =
          self.nixosConfigurations.emmc-target.config.system.build.emmcImage;
        flash-emmc = import ./emmc-installer {
          pkgs = import srcs.nixpkgs { system = "x86_64-linux"; };
          emmcImage =
            self.nixosConfigurations.emmc-target.config.system.build.emmcImage;
        };
        uboot-rpi-arm64 = pkgsCross.buildUBoot {
          defconfig = "rpi_arm64_defconfig";
          extraMeta.platforms = [ "aarch64-linux" ];
          filesToInstall = [ "u-boot.bin" ];
        };
      };
    };
}
