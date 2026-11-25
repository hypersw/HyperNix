# VmWarpProxy guest: Cloudflare WARP plus local proxies, reachable only via the
# host's 127.0.0.1 forwards. Parameters are documented in nixos.nix.
{ VmName
, VmHostname
, TeamName
, GuestSubnet
, SocksHostPort
, SshHostPort
, HttpHostPort
, SshAuthorizedKeys
, SshIdentityFile
, StateDir
, IsTcgOnly
, Mem
, Vcpu
, VmMacAddress
}:
{ config, lib, pkgs, ... }:
let
  HasHttpProxy = HttpHostPort != null;
  HostPkgs = config.microvm.vmHostPackages;
  # Accounts whose outbound traffic must go through the tunnel: the two proxies;
  # the login user, whose sshd session opens the ssh -W / -J connections; and
  # nscd, because nsncd performs every getaddrinfo lookup under its own uid.
  # warp-svc runs as root, loads no NSS module and resolves on its own, so it
  # still reaches the SLIRP resolver and the WARP API before enrollment.
  ProxyUsers = [ "microsocks" "warp" "nscd" ] ++ lib.optional HasHttpProxy "tinyproxy";
in
{
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "cloudflare-warp" ];

  microvm = {
    hypervisor = "qemu";
    # The runner's working directory is the state directory (the control
    # program sets it), so every host path below is relative to it.
    socket = "./VmControl.${VmName}.socket";
    mem = Mem;
    vcpu = Vcpu;

    # With cpu unset the runner passes -enable-kvm and `-cpu host`, both of
    # which die without /dev/kvm. Naming a CPU drops -enable-kvm, and the
    # machine's accel=kvm:tcg then falls back to pure emulation (TCG).
    cpu = if IsTcgOnly then "max" else null;
    # The microvm machine defaults to pit=off,pic=off, which leaves a TCG
    # guest without kvmclock no timer to calibrate against: it hangs right
    # after "Poking KASLR". KVM guests keep microvm.nix's defaults.
    qemu.machineOpts = lib.mkIf IsTcgOnly {
      accel = "tcg";
      acpi = "on";
      pit = "on";
      pic = "on";
      rtc = "on";
      pcie = "off";
      usb = "off";
    };

    # microvm.nix builds a user netdev without a `net=` knob, which would leave
    # the guest on SLIRP's default 10.0.2.0/24, a range an organisation may well
    # route into the tunnel. The netdev is therefore declared by hand.
    interfaces = [ ];
    qemu.extraArgs = [
      "-netdev"
      (lib.concatStringsSep "," ([
        "user"
        "id=warpnet"
        "net=${GuestSubnet}.0/24"                                # see GuestSubnet in nixos.nix
        "host=${GuestSubnet}.2"                                  # SLIRP gateway, the source address of every forwarded connection
        "dns=${GuestSubnet}.3"                                   # used only until warp-svc takes over resolv.conf
        "hostfwd=tcp:127.0.0.1:${toString SocksHostPort}-:1080"  # SOCKS5
        "hostfwd=tcp:127.0.0.1:${toString SshHostPort}-:22"      # enrollment shell, ssh -W / -J
      ] ++ lib.optionals HasHttpProxy [
        "hostfwd=tcp:127.0.0.1:${toString HttpHostPort}-:3128"   # HTTP proxy with CONNECT
      ]))
      "-device"
      # "-device" suffix: -M microvm without shares or graphics has no PCI bus.
      # Switch to virtio-net-pci if microvm.shares or graphics are ever added.
      "virtio-net-device,netdev=warpnet,mac=${VmMacAddress}"

      # vTPM: swtpm (started in preStart) behind a TIS frontend.
      "-chardev" "socket,id=chrtpm,path=./swtpm/swtpm.sock"
      "-tpmdev" "emulator,id=tpm0,chardev=chrtpm"
      "-device" "tpm-tis,tpmdev=tpm0"
    ];

    # Persistent TPM state; QEMU holds the control socket, and `terminate`
    # makes the emulator exit with QEMU. A reset re-inits the TPM but keeps
    # its persistent objects.
    preStart = ''
      # warp-state.img will hold the WARP device private key: create it 0600,
      # and repair an image that an older runner created 0644.
      umask 077
      if [ -e ./warp-state.img ]; then chmod 0600 ./warp-state.img; fi
      state_dir=./swtpm
      install -d -m 0700 "$state_dir"
      rm -f "$state_dir/swtpm.sock" "$state_dir/swtpm.pid"
      ${HostPkgs.swtpm}/bin/swtpm socket \
        --tpm2 \
        --tpmstate "dir=$state_dir,mode=0600,lock" \
        --ctrl "type=unixio,path=$state_dir/swtpm.sock,mode=0600,terminate" \
        --pid "file=$state_dir/swtpm.pid" \
        --log "file=$state_dir/swtpm.log,level=1" \
        --daemon
    '';

    # WARP's registration (reg.json with the device private key) lives in
    # /var/lib/cloudflare-warp. Losing it means another SSO enrollment.
    volumes = [{
      image = "./warp-state.img";
      mountPoint = "/var/lib/cloudflare-warp";
      size = 64;
      fsType = "ext4";
    }];
  };

  networking.hostName = VmHostname;
  system.stateVersion = lib.trivial.release;

  systemd.network = {
    enable = true;
    networks."20-slirp" = {
      matchConfig.Type = "ether";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = false;
        LinkLocalAddressing = "no";
      };
      # warp-svc owns /etc/resolv.conf once connected; networkd must not
      # push the SLIRP resolver back on a DHCP renewal.
      dhcpV4Config.UseDNS = false;
    };
  };
  services.resolved.enable = false;
  # Only until warp-svc connects and rewrites resolv.conf to its own proxy.
  # Without it the WARP API is unreachable and enrollment fails.
  networking.nameservers = [ "${GuestSubnet}.3" ];
  networking.enableIPv6 = false;

  # Enrollment is interactive, once per state directory: `control enroll`.
  # warp-svc remembers the connected state across reboots.
  services.cloudflare-warp.enable = true;

  # Unauthenticated, but reachable only through the hostfwd on the host's
  # 127.0.0.1; any local user of the host can use it.
  services.microsocks = {
    enable = true;
    ip = "0.0.0.0";
    port = 1080;
  };

  # The same egress for clients which take only HTTP_PROXY / HTTPS_PROXY.
  # CONNECT carries the host name, so names resolve here, inside the tunnel.
  # No ConnectPort line, so CONNECT reaches any port, as SOCKS does.
  services.tinyproxy = lib.mkIf HasHttpProxy {
    enable = true;
    settings = {
      Listen = "0.0.0.0";
      Port = 3128;
      # Every forwarded connection arrives from the SLIRP gateway.
      Allow = "${GuestSubnet}.2";
      DisableViaHeader = true;
      # The default level logs every plain-HTTP request line, query strings included.
      LogLevel = "Warning";
    };
  };

  users.users.warp = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = SshAuthorizedKeys;
  };
  # warp-cli registration needs root; the guest has no other secrets.
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    # The module would otherwise open 22 on every interface, WARP's included;
    # the eth0-only rule below is the one meant to admit it.
    openFirewall = false;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      AllowTcpForwarding = "yes";  # ssh -W / -J through the guest
    };
  };

  networking.firewall = {
    enable = true;
    # Only the SLIRP side, where the host's 127.0.0.1 forwards arrive. The
    # CloudflareWARP interface carries an organisation IP that other WARP
    # devices may reach, and an unauthenticated proxy there would be open to them.
    interfaces.eth0.allowedTCPPorts = [ 22 1080 ] ++ lib.optional HasHttpProxy 3128;
    # Egress guard: the proxies and SSH jumps may use eth0 only to answer the
    # host's forwarded connections, which all come from the SLIRP gateway.
    # Anything else they send there, including the SLIRP resolver, is refused,
    # so their traffic leaves only through the tunnel: nothing goes out directly
    # before enrollment or while WARP is down. Destinations the organisation
    # excludes from the tunnel are therefore unreachable through the proxies.
    # Only replies pass: a new connection to the gateway would reach the host's
    # own 127.0.0.1 services through SLIRP.
    # The guard is never removed: a firewall reload runs the stop commands
    # first, and removing the jumps there would open a window, or leave the
    # proxies unguarded if the reload fails. The guest is immutable, so the
    # rules never need to change while it runs.
    # Each rule is checked and added on its own, and the chain is complete
    # before any jump to it exists, so an interrupted run never attaches a
    # chain without its REJECT.
    extraCommands = ''
      iptables -w -N warp-proxy-egress 2>/dev/null || true
      iptables -w -C warp-proxy-egress -j REJECT 2>/dev/null \
        || iptables -w -A warp-proxy-egress -j REJECT
      iptables -w -C warp-proxy-egress -d ${GuestSubnet}.2 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null \
        || iptables -w -I warp-proxy-egress 1 -d ${GuestSubnet}.2 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    '' + lib.concatMapStrings (User: ''
      iptables -w -C OUTPUT -o eth0 -m owner --uid-owner ${User} -j warp-proxy-egress 2>/dev/null \
        || iptables -w -A OUTPUT -o eth0 -m owner --uid-owner ${User} -j warp-proxy-egress
    '') ProxyUsers;
  };

  # -M microvm puts the TPM (MSFT0101) into its DSDT but builds no TPM2 ACPI
  # table, and it ignores -acpitable. tpm_tis then rejects the ACPI device with
  # "[Firmware Bug]: failed to get TPM2 ACPI table" (-EINVAL) and no
  # /dev/tpmrm0 appears. force=1 probes the standard TIS window at 0xFED40000
  # directly, which is where QEMU's tpm-tis frontend sits.
  boot.kernelParams = [ "tpm_tis.force=1" ];

  security.tpm2 = {
    enable = true;
    tctiEnvironment.enable = true;
  };

  environment.systemPackages = [ pkgs.curl pkgs.dig pkgs.tpm2-tools ];

  # The host-side control program, with this VM's runner and parameters baked in.
  system.build.control = HostPkgs.writeShellApplication {
    name = VmName;
    runtimeInputs = [ HostPkgs.openssh HostPkgs.systemd HostPkgs.coreutils HostPkgs.gnugrep HostPkgs.util-linux ];
    text = builtins.replaceStrings
      [
        "@unit@"
        "@runner@"
        "@team@"
        "@stateDir@"
        "@sshIdentityFile@"
        "@sshPort@"
        "@socksPort@"
      ]
      [
        VmName
        "${config.microvm.declaredRunner}"
        TeamName
        StateDir
        SshIdentityFile
        (toString SshHostPort)
        (toString SocksHostPort)
      ]
      (builtins.readFile ./control.sh);
  };
}
