{
	description = "NixOS in MicroVMs";

	inputs.microvm.url = "github:astro/microvm.nix";
	inputs.microvm.inputs.nixpkgs.follows = "nixpkgs";

	outputs = { self, nixpkgs, microvm }:
		let
			system = "x86_64-linux";
			VmNameBare = "SshFront";
			VmNamePrefixed = "Vm" + VmNameBare;
		in {
			#defaultPackage.${system} = self.packages.${system}.${VmNamePrefixed};
			packages.${system} = 
			{
				"${VmNamePrefixed}" = self.nixosConfigurations.${VmNamePrefixed}.config.microvm.declaredRunner;
			};

			nixosConfigurations = 
			{
				"${VmNamePrefixed}" = nixpkgs.lib.nixosSystem 
				{
					inherit system;
					modules = [
						microvm.nixosModules.microvm
						# Import NixOS hardened profile for comprehensive security hardening
						"${nixpkgs}/nixos/modules/profiles/hardened.nix"
						{
							microvm =
							{
								# PERSISTENT VOLUMES:
								# - Disabled to avoid VM startup failures and reduce complexity
								# - Logs are ephemeral (lost on reboot) - acceptable for this use case
								# - For persistent logs, consider remote syslog to host or log aggregation
								# - NOTE: logs are currently passthru thru QEMU to host journal
								/*
								volumes =
								[{
									mountPoint = "/var";
									image = "VmDisk.${VmNameBare}.var.img";
									size = 256;
								}];
								*/

								# SSH HOST KEYS:
								# - Without persistent volume, host keys regenerate on each rebuild
								# - This causes "host key changed" warnings for clients
								# - Solutions:
								#   1. Mount host keys from host via 9p share
								#   2. Use SOPS/agenix to decrypt keys at boot
								#   3. Accept regeneration (insecure - trains users to ignore warnings)
								# TODO: Implement host key persistence via SOPS

								# NIX STORE: Using self-contained squashfs image instead of 9p share
								# - Image contains ONLY packages needed by this VM (not entire host store)
								# - Read-only and compressed (~200-500MB)
								# - Better security: no access to host's other packages
								# - No 9p protocol vulnerabilities
								# - Trade-off: slower builds, larger image than 9p share
								interfaces = 
								[{
									type = "tap";
									id = "vm-${VmNameBare}";
									mac = "02:34:54:83:93:01";
								}];

								hypervisor = "qemu";
								socket = "/run/VmControl.${VmNameBare}.socket";

								# Resource limits for isolation and DoS prevention
								mem = 512;  # MB - sufficient for SSH bastion
								vcpu = 1;   # Single CPU core
							};

							# State version tracks the nixpkgs used to build this VM.
							# Safe because this VM is fully stateless and built externally.
							system.stateVersion = nixpkgs.lib.trivial.release;

							systemd.network =
							{
								enable = true;
								networks."20-lan" =
								{
									matchConfig.Type = "ether";
									networkConfig =
									{
										Address = ["192.168.1.8/24"];
										Gateway = "192.168.1.1";
										# DNS disabled - not needed for ProxyJump/bastion functionality
										# Users connect TO this host, or use it as ProxyJump (DNS resolution on client)
										# If users need to SSH FROM this host to other hosts by hostname, uncomment:
										# DNS = [ "1.1.1.1" "8.8.8.8" ];
										IPv6AcceptRA = false;
										LinkLocalAddressing = "no";  # Suppress fe80:: link-local
										DHCP = "no";
									};
								};
							};
							
							users.users =
							{
								#root.password = ""; # Uncomment to allow easy root login

								# Administrator account with sudo access - uncomment when needed for maintenance
								/*
								administrator =
								{
									isNormalUser = true;
									extraGroups = [ "wheel" ];
									openssh.authorizedKeys.keys =
									[
										"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJDi8/s9Ac9AyxZp2EvhsExaa4PQMbV0sMAIKJyWZ+HC gigabyte hypervisor"
										"ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCyKu/f0Im5mlGooc9fapJSlWjFfFOXYZTaf/8+x6HcMUo1jK19J1jHJGIspoEbcqhdxE4kKPNBWG4RgYZNoYvLCFOZfpB6JjbTJEYPg68VEbIvgxLCoH5SZu2VIPphKb1H0gSZfqozLMhdODqehR1ciNaX8X0MWAnkLWfDHTkHVh2ZSSPyqg7n39gFt8TaAZU4eXd7CzMz0BX57I5wqj4E2oykkpoEbcw2FUGqkGwZFLhVl3w6rtw3BsTfBb94RibN5opy2BIuL2ZiOYQe8vVefmi7SlkjsIix0vkdfCd0y7EqjkR1hb+8DL81Ba7YiF6iELY0p5euaR87eguVpCWL  CAPI:abe0e51770b633b3de74db67e26851abcfb2d0bf CN=Your Name"
									];
								};
								*/

								vpn =
								{
									isNormalUser = true;
									openssh.authorizedKeys.keys =
									[
										"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF18SzA/CWkX5tw0GnJOLlNm6ScpC4y0T/bQgtGZiCRV HyperJetVmSshFront"
									];
								};
							};

							# Disable sudo - bastion hosts don't need it for normal operation
							security.sudo.enable = false;

							# Disable IPv6 entirely (CIS Level 2, reduces attack surface)
							networking.enableIPv6 = false;
							boot.kernel.sysctl = {
								"net.ipv6.conf.all.disable_ipv6" = 1;
								"net.ipv6.conf.default.disable_ipv6" = 1;
							};

							# Firewall configuration
							networking.firewall =
							{
								enable = true;
								allowedTCPPorts = [ 22 ]; # SSH only
								# Reject rather than drop for better UX
								rejectPackets = false;
							};

							# Kernel hardening - disable unused network protocols and subsystems
							boot.blacklistedKernelModules =
							[
								# Uncommon network protocols
								"dccp" "sctp" "rds" "tipc"
								# Disable Bluetooth if not needed
								"bluetooth" "btusb"
								# Disable FireWire (DMA attack vector)
								"firewire-core" "firewire-ohci"
							];

							# Disable systemd-resolved - this VM has no DNS configured
							# Without this, resolved still runs and tries its built-in fallback servers
							services.resolved.enable = false;

							# Disable login console on serial port (SSH-only bastion, ttyS0 is for logging)
							systemd.services."serial-getty@ttyS0".enable = false;

							# Forward VM journal to serial console → QEMU stdio → host journal
							# View on host with: journalctl -u RunSshFront.service
							# ForwardToKMsg doesn't work post-boot (hardened kernel lockdown blocks /dev/kmsg writes)
							# ForwardToConsole works but journald adds ANSI escape codes by default,
							# causing binary blob output in host journal - SYSTEMD_COLORS=0 fixes this
							services.journald.extraConfig = ''
								ForwardToConsole=yes
								TTYPath=/dev/ttyS0
								MaxLevelConsole=info
							'';
							systemd.services.systemd-journald.environment.SYSTEMD_COLORS = "0";

							# Heartbeat: log basic VM health metrics every 5 minutes
							systemd.timers.heartbeat =
							{
								wantedBy = [ "timers.target" ];
								timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "5min"; };
							};
							systemd.services.heartbeat =
							{
								description = "VM heartbeat with system metrics";
								serviceConfig =
								{
									Type = "oneshot";
									StandardOutput = "journal+console";
									StandardError = "journal+console";
									TTYPath = "/dev/ttyS0";
									ExecStart = "/bin/sh -c " + "''" +
										''
										set -x
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

										logger -t heartbeat "up=''${up_h}h''${up_m}m mem=''${mem_pct}%(''${mem_used_mb}/''${mem_total_mb}MB) load=''${load1}/''${load5}/''${load15} ssh=''${ssh_count} banned=''${banned:-0} net=rx:''${rx:-?}MB/tx:''${tx:-?}MB procs=$procs entropy=$entropy"
									'' + "''";
								};
							};


							services =
							{
								# Fail2ban for brute-force protection
								fail2ban =
								{
									enable = true;
									maxretry = 5;
									bantime = "1h";
									ignoreIP = [
										# Add trusted IPs here if needed
										# "192.168.1.0/24"
									];
								};

								openssh =
								{
									enable = true;
									settings =
									{
										PermitRootLogin = "no"; # SSH for extra users only
										PasswordAuthentication = false; # Keys only

										# GatewayPorts allows authenticated users to bind reverse tunnels to network interfaces
										# This is intentional - this bastion provides full network access to AUTHENTICATED users
										GatewayPorts = "clientspecified";

										# Connection limits to prevent resource exhaustion
										MaxAuthTries = 3;
										MaxStartups = "10:30:60"; # Allow 10 concurrent, drop probability 30% until 60

										# Additional hardening
										X11Forwarding = false;
										PermitUserEnvironment = false;
									};
								};
							};
						}
					];
				};
			};
		};
}
