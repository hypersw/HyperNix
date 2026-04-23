# VmSshFront machine configuration — SSH bastion MicroVM
{ VmNameBare, VmNamePrefixed }:
{ config, lib, pkgs, ... }:
{
  microvm = {
    interfaces = [{
      type = "tap";
      id = "vm-${VmNameBare}";
      mac = "02:34:54:83:93:01";
    }];
    hypervisor = "qemu";
    socket = "/run/VmControl.${VmNameBare}.socket";
    mem = 512;
    vcpu = 1;
  };

  system.stateVersion = lib.trivial.release;

  systemd.network = {
    enable = true;
    networks."20-lan" = {
      matchConfig.Type = "ether";
      networkConfig = {
        Address = [ "192.168.1.8/24" ];
        Gateway = "192.168.1.1";
        IPv6AcceptRA = false;
        LinkLocalAddressing = "no";
        DHCP = "no";
      };
    };
  };

  users.users.vpn = {
    isNormalUser = true;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF18SzA/CWkX5tw0GnJOLlNm6ScpC4y0T/bQgtGZiCRV HyperJetVmSshFront"
    ];
  };

  security.sudo.enable = false;

  networking.enableIPv6 = false;
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.disable_ipv6" = 1;
    "net.ipv6.conf.default.disable_ipv6" = 1;
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    rejectPackets = false;
  };

  boot.blacklistedKernelModules = [
    "dccp" "sctp" "rds" "tipc"
    "bluetooth" "btusb"
    "firewire-core" "firewire-ohci"
  ];

  services.resolved.enable = false;
  systemd.services."serial-getty@ttyS0".enable = false;

  services.journald.extraConfig = ''
    ForwardToConsole=yes
    TTYPath=/dev/ttyS0
    MaxLevelConsole=info
  '';
  systemd.services.systemd-journald.environment.SYSTEMD_COLORS = "0";

  systemd.timers.heartbeat = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "5min"; };
  };
  systemd.services.heartbeat = {
    description = "VM heartbeat with system metrics";
    serviceConfig = {
      WorkingDirectory = "/var/empty";  # safe CWD — see Modules/PrintersScanners/Daemon/default.nix
      Type = "oneshot";
      ExecStart = "/bin/sh -c " + "''" + ''
        read up_raw idle < /proc/uptime
        up_sec=''${up_raw%.*}
        up_h=$((up_sec / 3600))
        up_m=$(((up_sec % 3600) / 60))

        mem_total=$(grep "^MemTotal:" /proc/meminfo | tr -s " " | cut -d" " -f2)
        mem_avail=$(grep "^MemAvailable:" /proc/meminfo | tr -s " " | cut -d" " -f2)
        mem_used=$((mem_total - mem_avail))
        mem_pct=$((mem_used * 100 / mem_total))
        mem_total_mb=$((mem_total / 1024))
        mem_used_mb=$((mem_used / 1024))

        read load1 load5 load15 rest < /proc/loadavg

        ssh_count=$(ss -tnp 2>/dev/null | grep ":22 " | grep -c ESTAB || echo 0)

        banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | tr -s "	 " " " | rev | cut -d" " -f1 | rev)

        for iface in eth0 ens3 enp0s1 enp0s2; do
          if [ -d "/sys/class/net/$iface" ]; then
            rx=$(($(cat /sys/class/net/$iface/statistics/rx_bytes) / 1048576))
            tx=$(($(cat /sys/class/net/$iface/statistics/tx_bytes) / 1048576))
            break
          fi
        done

        procs=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
        entropy=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null)

        echo "heartbeat: up=''${up_h}h''${up_m}m mem=''${mem_pct}%(''${mem_used_mb}/''${mem_total_mb}MB) load=''${load1}/''${load5}/''${load15} ssh=''${ssh_count} banned=''${banned:-0} net=rx:''${rx:-?}MB/tx:''${tx:-?}MB procs=$procs entropy=$entropy" > /dev/ttyS0
      '' + "''";
    };
  };

  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    ignoreIP = [];
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      GatewayPorts = "clientspecified";
      MaxAuthTries = 3;
      MaxStartups = "10:30:60";
      X11Forwarding = false;
      PermitUserEnvironment = false;
    };
  };
}
