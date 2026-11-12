{ ... }:
# VdsRuOne -- minimal x86_64 NixOS VPS at VDSina.
#
# The two update lanes are intentionally independent.  Rollouts refresh only
# HyperNix (`upstream`), while the weekly transaction refreshes all three
# inputs in a sandbox and promotes its lock only after the build succeeds.
{
  imports = [ ../../../Modules ];

  networking = {
    hostName = "VdsRuOne";
    useDHCP = false;
    interfaces.ens3.ipv4.addresses = [{ address = "109.172.90.149"; prefixLength = 24; }];
    defaultGateway = { address = "109.172.90.1"; interface = "ens3"; };
    nameservers = [ "1.1.1.1" "8.8.8.8" ];
    firewall.allowedTCPPorts = [ 22 ];
  };

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/4ea42261-e3c2-4430-b17c-f2d4982cac42";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  boot = {
    loader.grub = {
      enable = true;
      device = "/dev/vda";
      configurationLimit = 2;
    };
    initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_scsi" "ext4" ];
    kernel.sysctl."vm.swappiness" = 10;
  };

  # Safety net for 1 GiB RAM, not a promise that nixpkgs can be compiled
  # locally. Builds are serial and are expected to substitute.
  zramSwap = { enable = true; memoryPercent = 50; algorithm = "zstd"; };
  swapDevices = [{ device = "/var/swapfile"; size = 1024; }];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
  users.users.root = {
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAABBBCUDA5mPmqJa0jn4SnZs0Z9sO7nN1JZiTzJjuD38UhRt45heumwYTh+Vz5QYpbX165I1a3VgAEffybsKAnWLr+8= vdsina01"
    ];
  };

  nix = {
    settings = { auto-optimise-store = true; max-jobs = 1; cores = 1; };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
      persistent = true;
    };
    optimise.automatic = true;
  };

  # /etc/nixos/flake.nix is module-owned; flake.lock remains operational
  # state, changed by the update services.  No candidate quartet or Pi input:
  # those would consume source-store space without benefiting this VPS.
  system.activationScripts.vdsRuOneLocalFlake.text = ''
    install -d -m 0755 /etc/nixos
    tmp=$(mktemp /etc/nixos/.flake.nix.XXXXXX)
    cat > "$tmp" <<'EOF'
    {
      description = "VdsRuOne local update shim";
      inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
        nixos-hardware.url = "github:NixOS/nixos-hardware";
        upstream = {
          url = "github:hypersw/HyperNix";
          inputs.nixpkgs.follows = "nixpkgs";
          inputs.nixos-hardware.follows = "nixos-hardware";
        };
      };
      outputs = { upstream, ... }: {
        nixosConfigurations.default = upstream.nixosConfigurations.VdsRuOne;
      };
    }
    EOF
    chmod 0644 "$tmp"
    mv -f "$tmp" /etc/nixos/flake.nix
  '';

  hypersw.services.auto-rebuild-on-push = {
    enable = true;
    onFailure = [];
  };
  hypersw.system.autoUpgradeTransactional = {
    enable = true;
    productionInputs = [ "nixpkgs" "nixos-hardware" "upstream" ];
    onFailureUnit = null;
  };

  system.stateVersion = "26.05";
}
