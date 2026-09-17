# VmSshFront machine configuration — SSH bastion MicroVM
{ VmNameBare
, VmNamePrefixed
, VmMacAddress
, VmIpv4Address
, VmGatewayAddress
, VmHostname
}:
let
  VmStateDir = "/var/lib/${VmNamePrefixed}";
in
{ config, lib, pkgs, ... }:
{
  microvm = {
    interfaces = [{
      type = "tap";
      id = "vm-${VmNameBare}";
      mac = VmMacAddress;
    }];
    hypervisor = "qemu";
    socket = "/run/VmControl.${VmNameBare}.socket";
    mem = 512;
    vcpu = 1;

    # The host only carries swtpm's opaque state, not SSH configuration or a
    # raw SSH private key. It must survive image rebuilds, otherwise the TPM
    # identity is lost.
    preStart = ''
      state_dir=${VmStateDir}/swtpm
      socket="$state_dir/swtpm.sock"
      pid_file="$state_dir/swtpm.pid"
      install -d -m 0700 "$state_dir"

      # A live process here means the runner previously crashed or was killed.
      # Normal QEMU shutdown closes swtpm's control connection and stops it.
      if [ -r "$pid_file" ]; then
        old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
          printf '%s\n' "stale swtpm process (PID $old_pid) found before VM start; terminating it to protect the persistent TPM state" \
            | ${config.microvm.vmHostPackages.systemd}/bin/systemd-cat --priority=err --identifier=${VmNamePrefixed}-swtpm
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
      "-chardev" "socket,id=chrtpm,path=${VmStateDir}/swtpm/swtpm.sock"
      "-tpmdev" "emulator,id=tpm0,chardev=chrtpm"
      # microvm retains an ISA bus; tpm-tis is the matching TPM frontend.
      "-device" "tpm-tis,tpmdev=tpm0"
    ];

    # This volume stores PKCS#11 token metadata and TPM-wrapped blobs, never a
    # raw SSH private key. It is needed to find the key after a VM rebuild.
    volumes = [{
      image = "${VmStateDir}/tpm2-pkcs11.img";
      mountPoint = "/var/lib/tpm2-pkcs11";
      size = 32;
      fsType = "ext4";
    }];
  };

  networking.hostName = VmHostname;

  system.stateVersion = lib.trivial.release;

  systemd.network = {
    enable = true;
    networks."20-lan" = {
      matchConfig.Type = "ether";
      networkConfig = {
        Address = [ VmIpv4Address ];
        Gateway = VmGatewayAddress;
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

  # Migrated off services.journald.extraConfig, which nixpkgs turned into a
  # hard assertion rather than a warning, so its presence fails the build
  # outright. settings.Journal is the structured replacement; values go
  # through systemd unit-option coercion, hence the bool rather than "yes".
  services.journald.settings.Journal = {
    ForwardToConsole = true;
    TTYPath = "/dev/ttyS0";
    MaxLevelConsole = "info";
  };
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

  # sshd never reads a private host-key file and never learns which of the two
  # paths below produced the key it is serving. It is pointed at one public key
  # and one agent socket; this service guarantees both exist, with the vTPM
  # behind them when the vTPM works and a throwaway key when it does not.
  #
  # The guarantee is the point. A bastion that will not accept SSH is worse in
  # every way than one whose host key rotates: the first costs you access to
  # the infrastructure, the second costs you a warning. So nothing in here is
  # allowed to fail the unit — no set -e, every TPM step is attempted and its
  # failure is a reason to fall back rather than to give up.
  systemd.services.ssh-hostkey-agent = {
    description = "OpenSSH host-key agent (vTPM-backed, with a throwaway fallback)";
    wantedBy = [ "multi-user.target" ];
    before = [ "sshd.service" ];
    requiredBy = [ "sshd.service" ];
    # Deliberately no dev-tpmrm0.device dependency. Wanting a device unit for
    # a device that never appears leaves systemd printing "Expecting device
    # /dev/tpmrm0..." indefinitely, and sshd — ordered after this — never
    # starts at all. The script waits for the device briefly and then decides,
    # which is the same race handled without betting the bastion on the
    # outcome.
    after = [ "local-fs.target" ];
    wants = [ "local-fs.target" ];

    serviceConfig = {
      Type = "simple";
      RuntimeDirectory = "ssh-hostkey-agent";
      RuntimeDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = "5s";
      # Type=simple counts the unit as started the moment it execs, so without
      # this sshd could be ordered after a service whose socket and public key
      # do not exist yet. ExecStartPost holds the start job until they do.
      ExecStartPost = pkgs.writeShellScript "ssh-hostkey-agent-ready" ''
        for _ in $(seq 1 100); do
          # A published public key plus either a private half or a loaded
          # agent is exactly what sshd needs; anything less and it would
          # start only to exit with "no hostkeys available".
          if [ -s /run/ssh-hostkey-agent/ssh_host_ecdsa_key.pub ] \
             && { [ -s /run/ssh-hostkey-agent/ssh_host_ecdsa_key ] \
                  || SSH_AUTH_SOCK=/run/ssh-hostkey-agent/agent.sock /bin/ssh-add -l >/dev/null 2>&1; }; then
            exit 0
          fi
          sleep 0.1
        done
        echo "host-key agent did not publish a key and socket in time" >&2
        exit 1
      '';
    };

    path = [ pkgs.coreutils pkgs.gnugrep pkgs.openssh pkgs.tpm2-pkcs11-esapi ];
    script = ''
      # No -e on purpose: see the comment above the unit.
      set -uo pipefail

      export TPM2_PKCS11_STORE=/var/lib/tpm2-pkcs11
      export TPM2TOOLS_TCTI=device:/dev/tpmrm0
      export TPM2_PKCS11_TCTI=device:/dev/tpmrm0
      export TSS2_LOG=fapi+NONE

      provider=${pkgs.tpm2-pkcs11-esapi}/lib/libtpm2_pkcs11.so
      runtime=/run/ssh-hostkey-agent
      socket="$runtime/agent.sock"
      # sshd is pointed at the PRIVATE path. With only the .pub present it has
      # no private half to read and falls through to HostKeyAgent, which is the
      # vTPM path. When the fallback writes a real private key here, sshd reads
      # it directly and the agent stops mattering at all — one less moving part
      # in the path that exists precisely because something else already broke.
      private_key="$runtime/ssh_host_ecdsa_key"
      public_key="$runtime/ssh_host_ecdsa_key.pub"
      token_label=sshd-host
      key_label=sshd-host
      # This only gates the PKCS#11 API. The unattended server cannot keep a
      # secret PIN; the TPM's non-exportable key is the protection here.
      user_pin=vm-sshd-host-key
      so_pin=vm-sshd-so-key

      install -d -m 0700 "$runtime"

      # Give udev a moment before concluding there is no TPM. Short, because
      # guessing wrong only rotates a host key, while waiting delays SSH on a
      # machine whose entire purpose is SSH.
      for _ in $(seq 1 50); do
        [ -e /dev/tpmrm0 ] && break
        sleep 0.1
      done

      PrepareTpmKey()
      {
        [ -e /dev/tpmrm0 ] || { echo "no /dev/tpmrm0 in this guest" >&2; return 1; }

        install -d -m 0700 "$TPM2_PKCS11_STORE" || return 1

        # Guard on the primary object, not on the database file. `init` creates
        # the sqlite store first and the primary afterwards, so an init that
        # fails partway leaves a database behind with no primary in it. A guard
        # that only checks for the file then skips init forever, and every
        # retry dies in addtoken with "No primary object id: 1".
        if ! tpm2_ptool listprimaries 2>/dev/null | grep -qE "(^|[^0-9])id: 1([^0-9]|$)"; then
          tpm2_ptool init || return 1
        fi
        if ! tpm2_ptool listtokens --pid=1 2>/dev/null | grep -Fq "CKA_LABEL: $token_label"; then
          tpm2_ptool addtoken --pid=1 --label="$token_label" \
            --sopin="$so_pin" --userpin="$user_pin" || return 1
        fi
        if ! tpm2_ptool listobjects --label="$token_label" 2>/dev/null | grep -Fq "CKA_LABEL: $key_label"; then
          tpm2_ptool addkey --label="$token_label" --userpin="$user_pin" \
            --algorithm=ecc256 --key-label="$key_label" || return 1
        fi

        ssh-keygen -D "$provider" 2>/dev/null | grep -F " $key_label" > "$public_key.tpm" || return 1
        [ -s "$public_key.tpm" ] || return 1

        # Publish only after the agent is proven to hold the matching key, so a
        # half-built TPM path never leaves sshd advertising something unusable.
        return 0
      }

      PublishFallbackKey()
      {
        # ecdsa to match the TPM key's type, so the file name stays accurate
        # and sshd sees the same algorithm either way. Regenerated only when
        # absent, so restarting this unit within one boot does not rotate the
        # key under live connections.
        if [ ! -s "$private_key" ]; then
          rm -f "$private_key" "$public_key"
          ssh-keygen -q -t ecdsa -b 256 -N "" -C "throwaway host key" -f "$private_key" || return 1
        fi
        [ -s "$private_key" ] && [ -s "$public_key" ]
      }

      # Start the agent first and wait for its socket. ssh-agent -D binds the
      # socket a moment after it is forked, so an ssh-add fired straight after
      # the & loses the race, reports "Error connecting to agent", and leaves
      # the agent empty — with sshd then advertising a key nothing can sign
      # for. Waiting is the whole fix.
      ssh-agent -D -a "$socket" &
      agent_pid=$!
      trap 'kill "$agent_pid" 2>/dev/null || true; wait "$agent_pid" 2>/dev/null || true' EXIT INT TERM
      export SSH_AUTH_SOCK="$socket"

      for _ in $(seq 1 100); do
        [ -S "$socket" ] && break
        sleep 0.1
      done

      AgentHoldsKey() { ssh-add -l >/dev/null 2>&1; }

      tpm_ok=no
      if PrepareTpmKey; then
        export SSH_ASKPASS_REQUIRE=force
        export SSH_ASKPASS=${pkgs.writeShellScript "ssh-hostkey-agent-askpass" ''
          printf '%s\n' "$user_pin"
        ''}
        if ssh-add -s "$provider" </dev/null && AgentHoldsKey; then
          # Only now is the TPM key real: remove any private key a previous
          # fallback left behind, or sshd would read that instead of asking
          # the agent, and quietly keep serving the throwaway identity.
          rm -f "$private_key"
          mv -f "$public_key.tpm" "$public_key"
          tpm_ok=yes
          echo "host key: vTPM-backed, non-exportable, stable across rebuilds"
        else
          echo "host key: PKCS#11 key would not load into the agent" >&2
        fi
        unset SSH_ASKPASS SSH_ASKPASS_REQUIRE
      fi
      rm -f "$public_key.tpm"

      if [ "$tpm_ok" = no ]; then
        echo "host key: vTPM unavailable; using a throwaway key in /run" >&2
        echo "host key: clients will see a changed host key after every VM boot" >&2
        if ! PublishFallbackKey; then
          echo "host key: could not produce a fallback key either" >&2
          exit 1
        fi
        # Loading it is a convenience, not a requirement: sshd reads the
        # private key at $private_key directly. Failure here is not fatal.
        ssh-add "$private_key" </dev/null || true
      fi

      wait "$agent_pid"
    '';
  };
  services.openssh = {
    enable = true;
    generateHostKeys = false;
    hostKeys = [];
    settings = {
      # A public HostKey plus HostKeyAgent means sshd never reads a private
      # host-key file: the agent supplies every signature, from the vTPM when
      # that works and from a throwaway key in /run when it does not. sshd is
      # deliberately unaware of which — one path here, decided at runtime by
      # ssh-hostkey-agent, so no failure of the vTPM can leave sshd without a
      # key to serve.
      HostKey = "/run/ssh-hostkey-agent/ssh_host_ecdsa_key";
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
