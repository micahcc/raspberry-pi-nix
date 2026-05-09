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
    rpi-linux-6_12_17-src = {
      flake = false;
      url = "github:raspberrypi/linux/rpi-6.12.y";
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
      url = "github:raspberrypi/libcamera/69a894c4adad524d3063dd027f5c4774485cf9db"; # v0.3.1+rpt20240906
    };
    libpisp-src = {
      flake = false;
      url = "github:raspberrypi/libpisp/v1.0.7";
    };
  };

  outputs = srcs@{ self, ... }:
    let
      pinned = import srcs.nixpkgs {
        system = "aarch64-linux";
        overlays = with self.overlays; [ core libcamera ];
      };
    in
    {
      overlays = {
        core = import ./overlays (builtins.removeAttrs srcs [ "self" ]);
        libcamera = import ./overlays/libcamera.nix (builtins.removeAttrs srcs [ "self" ]);
      };
      nixosModules = {
        raspberry-pi = import ./rpi {
          inherit pinned;
          core-overlay = self.overlays.core;
          libcamera-overlay = self.overlays.libcamera;
        };
        sd-image = import ./sd-image;
        nvme-installer = import ./nvme-installer;
        nvme-target = import ./nvme-installer/target.nix;
      };
      nixosConfigurations = {
        rpi-example = srcs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [ self.nixosModules.raspberry-pi self.nixosModules.sd-image ./example ];
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
            {
              raspberry-pi-nix.board = "bcm2712";
              users.users.root.initialPassword = "nixos";
              networking.hostName = "rpi5-installer";
              networking.useDHCP = true;
              services.openssh.enable = true;
              nvme-installer = {
                enable = true;
                targetSystem = self.nixosConfigurations.nvme-target;
              };
            }
          ];
        };
      };
      checks.aarch64-linux = self.packages.aarch64-linux;
      packages.aarch64-linux = with pinned.lib;
        let
          kernels =
            foldlAttrs f { } pinned.rpi-kernels;
          f = acc: kernel-version: board-attr-set:
            foldlAttrs
              (acc: board-version: drv: acc // {
                "linux-${kernel-version}-${board-version}" = drv;
              })
              acc
              board-attr-set;
        in
        {
          example-sd-image = self.nixosConfigurations.rpi-example.config.system.build.sdImage;
          nvme-installer-sd-image = self.nixosConfigurations.nvme-installer.config.system.build.sdImage;
          firmware = pinned.raspberrypifw;
          libcamera = pinned.libcamera;
          wireless-firmware = pinned.raspberrypiWirelessFirmware;
          uboot-rpi-arm64 = pinned.uboot-rpi-arm64;
        } // kernels;
    };
}
