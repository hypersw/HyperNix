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
						{
							microvm = 
							{
								/*
								volumes = 
								[{
									mountPoint = "/var";
									image = "VmDisk.${VmNameBare}.var.img";
									size = 256;
								}];
								*/
								shares = 
								[{
									#proto = "virtiofs"; #TODO: qemu-system-x86_64: -chardev socket,id=fs0,path=nixos-virtiofs-ro-store.sock: Failed to connect to 'nixos-virtiofs-ro-store.sock': No such file or directory
									proto = "9p"; # use "virtiofs" for MicroVMs that are started by systemd
									tag = "ro-store";
									source = "/nix/store"; # a host's /nix/store will be picked up so that no squashfs/erofs will be built for it.
									mountPoint = "/nix/.ro-store";
								}];
								interfaces = 
								[{
									type = "tap";
									id = "vm-${VmNameBare}";
									mac = "02:34:54:83:93:01";
								}];

								hypervisor = "qemu";
								socket = "/run/VmControl.${VmNameBare}.socket";
							};

							system.stateVersion = "23.11";

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
										DNS = [ "1.1.1.1" "8.8.8.8" ];
										IPv6AcceptRA = true;
										DHCP = "no";
									};
								};
							};
							
							users.users =
							{
								#root.password = ""; # Uncomment to allow easy root login
								administrator =
								{
									isNormalUser = true;
									extraGroups = [ "wheel" "networkmanager" ];
									openssh.authorizedKeys.keys = 
									[
										"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJDi8/s9Ac9AyxZp2EvhsExaa4PQMbV0sMAIKJyWZ+HC gigabyte hypervisor"
										"ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCyKu/f0Im5mlGooc9fapJSlWjFfFOXYZTaf/8+x6HcMUo1jK19J1jHJGIspoEbcqhdxE4kKPNBWG4RgYZNoYvLCFOZfpB6JjbTJEYPg68VEbIvgxLCoH5SZu2VIPphKb1H0gSZfqozLMhdODqehR1ciNaX8X0MWAnkLWfDHTkHVh2ZSSPyqg7n39gFt8TaAZU4eXd7CzMz0BX57I5wqj4E2oykkpoEbcw2FUGqkGwZFLhVl3w6rtw3BsTfBb94RibN5opy2BIuL2ZiOYQe8vVefmi7SlkjsIix0vkdfCd0y7EqjkR1hb+8DL81Ba7YiF6iELY0p5euaR87eguVpCWL  CAPI:abe0e51770b633b3de74db67e26851abcfb2d0bf CN=Your Name"
									];
								};
								vpn =
								{
									isNormalUser = true;
									openssh.authorizedKeys.keys = 
									[
										"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF18SzA/CWkX5tw0GnJOLlNm6ScpC4y0T/bQgtGZiCRV HyperJetVmSshFront"
									];
								};
								/*
								tmp =
								{
									isNormalUser = true;
									password = "CWkX5tw0GnJOLlNm6ScpC4y0T";
									openssh.authorizedKeys.keys = 
									[
										"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF18SzA/CWkX5tw0GnJOLlNm6ScpC4y0T/bQgtGZiCRV HyperJetVmSshFront"
									];
								};
								*/
							};

							services =
							{
								openssh =
								{
									enable = true;
									settings =
									{
										PermitRootLogin = "no"; # SSH for extra users only
										PasswordAuthentication = false; # Keys only
										GatewayPorts = "clientspecified";   # This is required for binding reverse tunnels to real network interfaces (like, accepting connections which will be put into the tunnel), otherwise that's localhost only
									};
								};
							};
						}
					];
				};
			};
		};
}
