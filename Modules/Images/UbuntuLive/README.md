# Ubuntu live VM image builder

The HyperNix flake exposes `lib.Modules-Images-UbuntuLive`, a Nix function returning a runnable builder
for an Ubuntu 26.10 GNOME live ISO. The default image includes Firefox from
Mozilla's DEB repository, FAR2L wx, curl, networking, GVFS and a virtual kernel.
It targets x86-64 QEMU and Hyper-V guests and has no Secure Boot support. It
requests text boot, hides the GRUB menu and disables audio by default.

Example consumer:

```nix
{
  inputs.hypernix.url = "github:hypersw/HyperNix";
  outputs = { hypernix, ... }:
    let
      system = "x86_64-linux";
      builder = hypernix.lib.Modules-Images-UbuntuLive {
        pkgs = hypernix.inputs.nixpkgs.legacyPackages.${system};
        packages = [ "cowsay" ];
        firefoxExtensions = [ {
          id = "uBlock0@raymondhill.net";
          url = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
        } ];
        resolution = "1920x1080";
        scale = 1;
        # extraFiles."/etc/example.conf" = ./example.conf;
        # firefoxPolicies = { ... };
        # disableAudio = false;
      };
    in {
      packages.${system}.default = builder;
      apps.${system}.default = {
        type = "app";
        program = "${builder}/bin/build-ubuntu-live";
      };
    };
}
```

After publication, `nix run github:hypersw/HyperNix#Modules-Images-UbuntuLive`
runs the default builder directly. For a customized image, run `nix run .`
from the consumer flake; use `-- --output /path` to choose an
output directory. The ISO and SHA-256 file go into `ubuntu-live-output` by
default. This runs a rootless Podman container with host network and PID
namespaces and `--privileged`; container storage and scratch are temporary.
It downloads Ubuntu packages and the extensions at build time; the image is
not bit-for-bit reproducible. Firefox verifies extension signatures when it
installs them. ISO contents and Nix store inputs are public: do not put secrets
in configuration, extensions, or extra files.

`packages` contains additional Ubuntu package names, not Nix packages.
`firefoxExtensions` is a list of `{ id, url }` objects, with HTTPS XPI URLs and
the Firefox add-on ID; the build rejects mismatched IDs. No extensions are
enabled by default. Firefox installs the bundled files into each new profile,
including offline, and users may disable them.

`resolution` defaults to `null` (auto). A `WIDTHxHEIGHT` string requests that
mode in GRUB and the kernel. A `scale` of 2 additionally attempts to configure
the mode and 200% scaling in a single-display Hyper-V GNOME session after login;
the mode must be supported. It falls back to the current display configuration
when unavailable. `scale` defaults to 1. The VM can ignore the mode request.

`network` defaults to `{ mode = "networkmanager"; }`, using DHCP as usual. To
use a named Ethernet interface with a static IPv4 address instead, configure:

```nix
network = {
  mode = "static";
  interface = "eth0";
  address = "192.0.2.10/24";
  gateway = "192.0.2.1"; # optional for proxies on the same subnet
};
```

Use the actual guest interface name, IP prefix and gateway. In static mode
`systemd-networkd` configures that interface; DHCP, IPv6 autoconfiguration,
NetworkManager and a DNS resolver are not configured. The build fails if a
requested package pulls in NetworkManager. SOCKS must be configured separately
in Firefox, with remote DNS enabled and a proxy address reachable over this
network. This is not a firewall: applications can still make direct connections
or perform their own DNS lookups. A gateway is needed if the proxy is off-link.

`firefoxPolicies` is recursively merged into the default Firefox enterprise
policies. These disable Firefox telemetry, studies and automatic crash
submission, and skip its initial terms notice. Mozilla says that the
`SkipTermsOfUse` policy represents acceptance of the applicable terms and
privacy notice on behalf of image users; see
https://firefox-admin-docs.mozilla.org/reference/policies/skiptermsofuse/.
Set `firefoxPolicies.SkipTermsOfUse = false` to retain the notice. Firefox
policy and extension controls cannot prevent all tracking or network requests.
Common Ubuntu reporting packages are rejected by a build check.

`extraFiles` maps absolute target paths to local Nix paths and copies them into
the guest after its standard configuration is written. This permits replacing
configuration files, so take care not to override the generated Firefox policy
unless intended. `disableAudio = false` stops masking audio services; the lean
base does not guarantee an audio stack is installed.
