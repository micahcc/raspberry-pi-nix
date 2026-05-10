# Example: NVMe target system configuration.
# Customize this for your desired NVMe-installed system.
{ pkgs, lib, ... }:
{
  raspberry-pi-nix.board = "bcm2712";

  time.timeZone = "America/Los_Angeles";

  users.users.root.initialPassword = "nixos";
  users.users.nixos = {
    isNormalUser = true;
    initialPassword = "nixos";
    extraGroups = [
      "wheel"
      "gpio"
      "i2c"
      "spi"
    ];
  };

  networking = {
    hostName = "rpi5-nvme";
    useDHCP = true;
  };

  services.openssh.enable = true;

  hardware.raspberry-pi.config = {
    all = {
      options = {
        hdmi_force_hotplug = {
          enable = true;
          value = 1;
        };
        usb_max_current_enable = {
          enable = true;
          value = 1;
        };
      };
      base-dt-params = {
        # Enable PCIe for NVMe
        pciex1 = {
          enable = true;
          value = 1;
        };
        pciex1_gen = {
          enable = true;
          value = 3;
        };
      };
      dt-overlays = {
        vc4-kms-v3d = {
          enable = true;
          params = { };
        };
      };
    };
  };
}
