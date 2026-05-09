# Example: NVMe target system configuration.
# Customize this for your desired NVMe-installed system.
{ pkgs, lib, ... }: {
  time.timeZone = "America/Los_Angeles";

  users.users.root.initialPassword = "nixos";
  users.users.nixos = {
    isNormalUser = true;
    initialPassword = "nixos";
    extraGroups = [ "wheel" "gpio" "i2c" "spi" ];
  };

  networking = {
    hostName = "rpi5-nvme";
    useDHCP = false;
    interfaces = {
      wlan0.useDHCP = true;
      eth0.useDHCP = true;
    };
  };

  services.openssh.enable = true;

  hardware.raspberry-pi.config = {
    all = {
      base-dt-params = {
        BOOT_UART = {
          value = 1;
          enable = true;
        };
        uart_2ndstage = {
          value = 1;
          enable = true;
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
