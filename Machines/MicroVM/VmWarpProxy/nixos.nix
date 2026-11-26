# Called from the root flake: hypernix.lib."Machines-MicroVM-VmWarpProxy" { VmName = …; TeamName = …; … }
#
# A microVM that joins a Cloudflare One (WARP) Zero Trust organisation.
# It publishes the tunnel as SOCKS5 (and optionally an HTTP proxy)
# on the host's 127.0.0.1 or ProxyListenAddress,
# plus SSH on 127.0.0.1 for enrollment and jumps.
# It touches no host networking and needs no root:
# QEMU user-mode networking with hostfwd, and under IsTcgOnly not even /dev/kvm.
# Several instances can run side by side, one per organisation,
# as long as VmName and the host ports differ.
#
# The result is a nixosSystem. Consumers take two outputs from it:
#   config.microvm.declaredRunner   the VM runner
#   config.system.build.control     start/stop/status/log/ssh/enroll for it, as a
#                                   transient systemd --user unit named VmName
#
# Limits a consumer must accept:
# - It trusts every local user of the host. The proxies take no credentials,
#   and the control program accepts any SSH host key on SshHostPort, because
#   the guest's key changes every boot. Do not use it on a shared host.
#   With a ProxyListenAddress other than 127.0.0.1, it trusts every machine
#   which can reach that address as well.
# - The proxies send nothing outside the tunnel (see the egress guard in
#   configuration.nix), so a host the organisation excludes from the tunnel
#   cannot be reached through them.
# - QEMU opens its disks with aio=io_uring; a container whose seccomp policy
#   blocks io_uring stops the runner before the guest boots.
# - Run the runner under a supervisor (the control program uses systemd): if
#   it fails between starting swtpm and QEMU, swtpm is left behind.
# - The control program roots the runner with the nix profile
#   <VmName>-runner. In a container which shares the host's nix daemon the
#   host GC cannot see a container-private profile unless the host roots it.
{ nixpkgs
, microvm
  # Names the systemd user unit, the QMP socket and the default state
  # directory, so it must be unique per machine.
, VmName
, VmHostname ? nixpkgs.lib.toLower VmName
  # The Cloudflare One team name, as in `warp-cli registration new <team>`.
, TeamName
  # First three octets of the guest's SLIRP /24 (e.g. "192.168.200"). It must lie
  # outside every range the organisation routes into the tunnel, or the replies
  # to forwarded connections disappear into it.
, GuestSubnet
, SocksHostPort
, SshHostPort
  # Host port for an HTTP proxy with CONNECT (tinyproxy), for clients which only
  # take HTTP_PROXY/HTTPS_PROXY. null leaves the HTTP proxy out.
, HttpHostPort ? null
  # Host IPv4 address the SOCKS5 and HTTP proxy ports listen on; "0.0.0.0" for
  # every interface, so that other machines can use the proxies. The proxies
  # are unauthenticated, so anything that reaches this address can use them.
  # SSH always stays on 127.0.0.1.
, ProxyListenAddress ? "127.0.0.1"
, SshAuthorizedKeys
  # Private half of a key in SshAuthorizedKeys, for the control program: a
  # path string, taken literally except that a leading "~/" means $HOME at
  # run time. Never a Nix path such as ./key: that would copy the private key
  # into the store.
, SshIdentityFile
  # Holds warp-state.img and swtpm/; losing it means a new enrollment. A path
  # string like SshIdentityFile; null means $XDG_STATE_HOME/<VmName>, or
  # ~/.local/state/<VmName> without XDG_STATE_HOME.
, StateDir ? null
  # No /dev/kvm (e.g. inside a container): run under TCG emulation.
, IsTcgOnly ? false
, Mem ? 1024
, Vcpu ? 2
, VmMacAddress ? "02:00:00:00:00:01"
  # Binds the WARP registration to a non-exportable key in the guest's TPM
  # (Cloudflare's MDM setting hardware_backed_registration, client 2026.6+).
  # Changing it invalidates the registration: enroll again afterwards.
, IsHardwareBackedRegistration ? false
  # Encrypts the swtpm state with a key that systemd-creds seals with the
  # host's TPM, scoped to the user; it needs a host TPM and systemd 256+.
  # The state on disk is then useless on another machine, but a process of
  # the same user here can still have it decrypted. Turning it on needs an
  # empty swtpm/ directory, so the TPM contents start fresh.
, IsTpmStateSealed ? false
  # A home-manager or NixOS module declares the instance's user unit (see
  # home.nix); the control program then starts and stops that unit instead of
  # a transient one.
, IsUnitDeclared ? false
, ExtraModules ? [ ]
}:
nixpkgs.lib.nixosSystem {
  modules = [
    { nixpkgs.hostPlatform.system = "x86_64-linux"; }
    microvm.nixosModules.microvm
    (import ./configuration.nix { inherit VmName VmHostname TeamName GuestSubnet SocksHostPort SshHostPort HttpHostPort ProxyListenAddress SshAuthorizedKeys SshIdentityFile StateDir IsTcgOnly Mem Vcpu VmMacAddress IsHardwareBackedRegistration IsTpmStateSealed IsUnitDeclared; })
  ] ++ ExtraModules;
}
