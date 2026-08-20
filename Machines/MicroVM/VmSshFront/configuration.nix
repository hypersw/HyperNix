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

    # The host only carries swtpm's opaque state, not SSH configuration or a
    # raw SSH private key. It must survive image rebuilds, otherwise the TPM
    # identity is lost.
    preStart = ''
      state_dir=/var/lib/VmSshFront/swtpm
      socket="$state_dir/swtpm.sock"
      pid_file="$state_dir/swtpm.pid"
      install -d -m 0700 "$state_dir"

      # A live process here means the runner previously crashed or was killed.
      # Normal QEMU shutdown closes swtpm's control connection and stops it.
      if [ -r "$pid_file" ]; then
        old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
          printf '%s\n' "stale swtpm process (PID $old_pid) found before VM start; terminating it to protect the persistent TPM state" \
            | ${config.microvm.vmHostPackages.systemd}/bin/systemd-cat --priority=err --identifier=VmSshFront-swtpm
          kill -TERM "$old_pid"
          while kill -0 "$old_pid" 2>/dev/null; do sleep 0.1; done
        fi
      fi
      rm -f "$socket" "$pid_file"

      # QEMU holds this control connection for the VM's lifetime. `terminate`
      # makes swtpm exit as soon as QEMU releases it, including after an
      # ungraceful QEMU death; no detached emulator is left behind.
      ${config.microvm.vmHostPackages.swtpm}/bin/swtpm socket \
        --tpm2 \
        --tpmstate "dir=$state_dir,mode=0700,lock" \
        --ctrl "type=unixio,path=$socket,mode=0600,terminate" \
        --pid "file=$pid_file" \
        --daemon
    '';

    qemu.extraArgs = [
      "-chardev" "socket,id=chrtpm,path=/var/lib/VmSshFront/swtpm/swtpm.sock"
      "-tpmdev" "emulator,id=tpm0,chardev=chrtpm"
      # microvm retains an ISA bus; tpm-tis is the matching TPM frontend.
      "-device" "tpm-tis,tpmdev=tpm0"
    ];

    # This volume stores PKCS#11 token metadata and TPM-wrapped blobs, never a
    # raw SSH private key. It is needed to find the key after a VM rebuild.
    volumes = [{
      image = "/var/lib/VmSshFront/tpm2-pkcs11.img";
      mountPoint = "/var/lib/tpm2-pkcs11";
      size = 32;
      fsType = "ext4";
    }];
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

  security.tpm2 = {
    enable = true;
    pkcs11 = {
      enable = true;
      package = pkgs.tpm2-pkcs11-esapi;
    };
    tctiEnvironment.enable = true;
  };

  # sshd receives the public half only. Every host-key signature is delegated
  # to this root-owned agent, whose loaded key remains inside the vTPM.
  systemd.services.ssh-hostkey-agent = {
    description = "TPM-backed OpenSSH host-key agent";
    wantedBy = [ "multi-user.target" ];
    before = [ "sshd.service" ];
    requiredBy = [ "sshd.service" ];
    after = [ "local-fs.target" ];
    wants = [ "local-fs.target" ];

    serviceConfig = {
      Type = "simple";
      RuntimeDirectory = "ssh-hostkey-agent";
      RuntimeDirectoryMode = "0700";
      Restart = "on-failure";
    };

    path = [ pkgs.coreutils pkgs.gnugrep pkgs.openssh pkgs.tpm2-pkcs11-esapi ];
    script = ''
      set -euo pipefail
      export TPM2_PKCS11_STORE=/var/lib/tpm2-pkcs11
      export TPM2TOOLS_TCTI=device:/dev/tpmrm0
      export TPM2_PKCS11_TCTI=device:/dev/tpmrm0
      export TSS2_LOG=fapi+NONE

      provider=${pkgs.tpm2-pkcs11-esapi}/lib/libtpm2_pkcs11.so
      socket=/run/ssh-hostkey-agent/agent.sock
      public_key=/run/ssh-hostkey-agent/ssh_host_ecdsa_key.pub
      token_label=sshd-host
      key_label=sshd-host
      # This only gates the PKCS#11 API. The unattended server cannot keep a
      # secret PIN; the TPM's non-exportable key is the protection here.
      user_pin=vm-sshd-host-key
      so_pin=vm-sshd-so-key

      install -d -m 0700 "$TPM2_PKCS11_STORE"
      if [ ! -e "$TPM2_PKCS11_STORE/tpm2_pkcs11.sqlite3" ]; then
        tpm2_ptool init
      fi
      if ! tpm2_ptool listtokens --pid=1 | grep -Fq "CKA_LABEL: $token_label"; then
        tpm2_ptool addtoken --pid=1 --label="$token_label" \
          --sopin="$so_pin" --userpin="$user_pin"
      fi
      if ! tpm2_ptool listobjects --label="$token_label" | grep -Fq "CKA_LABEL: $key_label"; then
        tpm2_ptool addkey --label="$token_label" --userpin="$user_pin" \
          --algorithm=ecc256 --key-label="$key_label"
      fi

      ${pkgs.openssh}/bin/ssh-keygen -D "$provider" \
        | grep -F " $key_label" > "$public_key"
      test -s "$public_key"

      ${pkgs.openssh}/bin/ssh-agent -D -a "$socket" &
      agent_pid=$!
      trap 'kill "$agent_pid" 2>/dev/null || true; wait "$agent_pid" 2>/dev/null || true' EXIT INT TERM
      export SSH_AUTH_SOCK="$socket"
      export SSH_ASKPASS_REQUIRE=force
      export SSH_ASKPASS=${pkgs.writeShellScript "ssh-hostkey-agent-askpass" ''
        printf '%s\n' "$user_pin"
      ''}
      ${pkgs.openssh}/bin/ssh-add -s "$provider" </dev/null
      wait "$agent_pid"
    '';
  };

  services.openssh = {
    enable = true;
    generateHostKeys = false;
    hostKeys = [];
    settings = {
      # A public HostKey plus HostKeyAgent means sshd never reads a private
      # host-key file: the vTPM-backed agent supplies every signature.
      HostKey = "/run/ssh-hostkey-agent/ssh_host_ecdsa_key.pub";
      HostKeyAgent = "/run/ssh-hostkey-agent/agent.sock";
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
