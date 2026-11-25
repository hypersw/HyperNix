# Called from the root flake: hypernix.lib."Machines-MicroVM-VmWarpProxy" { VmName = …; TeamName = …; … }
#
# A microVM that joins a Cloudflare One (WARP) Zero Trust organisation and
# publishes the tunnel as SOCKS5 (and optionally an HTTP proxy) on the host's
# 127.0.0.1, plus SSH for enrollment and jumps. It touches no host networking
# and needs no root: QEMU user-mode networking with hostfwd, and under
# IsTcgOnly not even /dev/kvm. Several instances can run side by side, one per
# organisation, as long as VmName and the host ports differ.
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
, SshAuthorizedKeys
  # Private half of a key in SshAuthorizedKeys, for the control program. A
  # shell string, expanded at run time, so "$HOME/…" works. Never a Nix path
  # such as ./key: that would copy the private key into the store.
, SshIdentityFile
  # Holds warp-state.img and swtpm/; losing it means a new enrollment. A shell
  # string, expanded at run time.
, StateDir ? "\${XDG_STATE_HOME:-$HOME/.local/state}/${VmName}"
  # No /dev/kvm (e.g. inside a container): run under TCG emulation.
, IsTcgOnly ? false
, Mem ? 1024
, Vcpu ? 2
, VmMacAddress ? "02:00:00:00:00:01"
, ExtraModules ? [ ]
}:
nixpkgs.lib.nixosSystem {
  modules = [
    { nixpkgs.hostPlatform.system = "x86_64-linux"; }
    microvm.nixosModules.microvm
    (import ./configuration.nix { inherit VmName VmHostname TeamName GuestSubnet SocksHostPort SshHostPort HttpHostPort SshAuthorizedKeys SshIdentityFile StateDir IsTcgOnly Mem Vcpu VmMacAddress; })
  ] ++ ExtraModules;
}
