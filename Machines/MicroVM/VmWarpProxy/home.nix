# Home-manager module: declares VmWarpProxy instances as systemd user units,
# with one control command per instance. Several instances can run side by
# side, typically one per Cloudflare One team.
#
#   services.warp-proxy = {
#     builder = <HyperNix>.lib."Machines-MicroVM-VmWarpProxy";   # the flake's homeModules set it
#     instances.<name> = { teamName = "…"; guestSubnet = "…"; socksPort = …; sshPort = …; … };
#   };
#
# Instance <name> becomes the unit warp-proxy-<name>.service, preceded by the
# oneshot warp-proxy-<name>-prepare.service, and the command warp-proxy-<name>
# (start, stop, status, log, ssh, enroll). The name is also the VM's name, so
# it scopes the default state directory and the control lock.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  Cfg = config.services.warp-proxy;

  # A path as the options take it ("~/…", absolute, or null for the default) in
  # unit-file syntax. It must match the control program's own expansion.
  UnitPath = VmName: Path:
    if Path == null then "%S/${VmName}"
    else if lib.hasPrefix "~/" Path then "%h/${lib.removePrefix "~/" Path}"
    else Path;

  Build = Name: Inst:
    let
      VmName = "warp-proxy-${Name}";
      Vm = Cfg.builder ({
        inherit VmName;
        TeamName = Inst.teamName;
        GuestSubnet = Inst.guestSubnet;
        SocksHostPort = Inst.socksPort;
        SshHostPort = Inst.sshPort;
        HttpHostPort = Inst.httpPort;
        SshAuthorizedKeys = Inst.sshAuthorizedKeys;
        SshIdentityFile = Inst.sshIdentityFile;
        StateDir = Inst.stateDir;
        IsTcgOnly = Inst.isTcgOnly;
        Mem = Inst.mem;
        Vcpu = Inst.vcpu;
        IsHardwareBackedRegistration = Inst.isHardwareBackedRegistration;
        IsTpmStateSealed = Inst.isTpmStateSealed;
        IsUnitDeclared = true;
        ExtraModules = Inst.extraModules;
      } // lib.optionalAttrs (Inst.vmHostname != null) { VmHostname = Inst.vmHostname; });
    in
    {
      inherit VmName;
      Runner = Vm.config.microvm.declaredRunner;
      Control = Vm.config.system.build.control;
      State = UnitPath VmName Inst.stateDir;
    };
  Built = lib.mapAttrs Build Cfg.instances;

  InstanceOptions = {
    options = {
      teamName = mkOption { type = types.str; description = "Cloudflare One team name, as in `warp-cli registration new <team>`."; };
      guestSubnet = mkOption { type = types.str; description = "First three octets of the guest's /24, outside every range the organisation routes into the tunnel."; };
      socksPort = mkOption { type = types.port; description = "Host port on 127.0.0.1 for SOCKS5."; };
      sshPort = mkOption { type = types.port; description = "Host port on 127.0.0.1 for the guest's SSH."; };
      httpPort = mkOption { type = types.nullOr types.port; default = null; description = "Host port on 127.0.0.1 for an HTTP CONNECT proxy; null leaves it out."; };
      sshAuthorizedKeys = mkOption { type = types.listOf types.str; description = "Public keys of the guest's login user."; };
      sshIdentityFile = mkOption { type = types.str; description = "Private half of one of those keys, as a path string; a leading \"~/\" means $HOME. Never a Nix path, which would copy the key into the store."; };
      stateDir = mkOption { type = types.nullOr types.str; default = null; description = "State directory (WARP disk image, vTPM, sealed key); a leading \"~/\" means $HOME; null means $XDG_STATE_HOME/warp-proxy-<name>."; };
      vmHostname = mkOption { type = types.nullOr types.str; default = null; description = "The guest's hostname, which Cloudflare shows as the device name; null derives it from the name."; };
      isTcgOnly = mkOption { type = types.bool; default = false; description = "Run under TCG emulation, for hosts without /dev/kvm."; };
      mem = mkOption { type = types.int; default = 1024; description = "Guest memory in MiB."; };
      vcpu = mkOption { type = types.int; default = 2; description = "Guest vCPUs."; };
      isHardwareBackedRegistration = mkOption { type = types.bool; default = false; description = "Bind the WARP registration to a key in the guest's TPM; changing it means a new enrollment."; };
      isTpmStateSealed = mkOption { type = types.bool; default = false; description = "Encrypt the vTPM state with a key sealed by the host's TPM; turning it on needs an empty swtpm/ directory."; };
      autoStart = mkOption { type = types.bool; default = true; description = "Start the instance with the user's systemd manager."; };
      extraModules = mkOption { type = types.listOf types.raw; default = [ ]; description = "Extra NixOS modules for the guest."; };
    };
  };

  # Two instances must not share a host port or a guest subnet.
  AllPorts = lib.concatMap (I: [ I.socksPort I.sshPort ] ++ lib.optional (I.httpPort != null) I.httpPort) (lib.attrValues Cfg.instances);
  AllSubnets = map (I: I.guestSubnet) (lib.attrValues Cfg.instances);
in
{
  options.services.warp-proxy = {
    builder = mkOption {
      type = types.nullOr types.raw;
      default = null;
      description = ''HyperNix's `lib."Machines-MicroVM-VmWarpProxy"`. The flake's homeModules set it; a configuration which imports this module by path passes it itself, for example through flake-compat.'';
    };
    instances = mkOption {
      type = types.attrsOf (types.submodule InstanceOptions);
      default = { };
      description = "VmWarpProxy instances, by name.";
    };
  };

  config = lib.mkIf (Cfg.instances != { }) {
    assertions = [
      { assertion = Cfg.builder != null; message = ''services.warp-proxy.builder is unset: set it to HyperNix's lib."Machines-MicroVM-VmWarpProxy".''; }
      { assertion = lib.length AllPorts == lib.length (lib.unique AllPorts); message = "services.warp-proxy: two instances share a host port."; }
      { assertion = lib.length AllSubnets == lib.length (lib.unique AllSubnets); message = "services.warp-proxy: two instances share a guest subnet."; }
    ];

    home.packages = lib.mapAttrsToList (_: B: B.Control) Built;

    systemd.user.services = lib.mkMerge (lib.mapAttrsToList (Name: Inst:
      let B = Built.${Name}; in
      {
        # Creates the state directory and, when sealed, the sealed key: systemd
        # loads credentials when the main unit starts, so the key must exist first.
        "${B.VmName}-prepare" = {
          Unit.Description = "${B.VmName}: prepare the state directory";
          Service = {
            Type = "oneshot";
            ExecStart = "${B.Control}/bin/${B.VmName} prepare";
          };
        };
        ${B.VmName} = {
          Unit = {
            Description = "${B.VmName}: WARP proxy microVM (SOCKS5 on 127.0.0.1:${toString Inst.socksPort})";
            Requires = [ "${B.VmName}-prepare.service" ];
            After = [ "${B.VmName}-prepare.service" ];
          };
          Service = {
            WorkingDirectory = B.State;
            ExecStart = "${B.Runner}/bin/microvm-run";
            # ExecStop asks QEMU over QMP to power the guest off; KillMode=mixed
            # then lets QEMU and swtpm exit before the rest is killed.
            ExecStop = "${B.Runner}/bin/microvm-shutdown";
            KillMode = "mixed";
            TimeoutStopSec = 60;
          } // lib.optionalAttrs Inst.isTpmStateSealed {
            LoadCredentialEncrypted = "swtpm-key:${B.State}/swtpm-key.cred";
          };
          Install = lib.optionalAttrs Inst.autoStart { WantedBy = [ "default.target" ]; };
        };
      }) Cfg.instances);
  };
}
