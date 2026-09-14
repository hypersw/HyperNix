{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
  tokenDir = "/home/${cfg.User}/.local/share/tpm2_pkcs11";
in
{
  config = lib.mkIf (cfg.Enable && cfg.Tpm.Enable) {
    programs.ssh-askpass-credential-helper = {
      enable = true;
      perTokenPin = false;
    };

    security.tpm2 = {
      enable = true;
      pkcs11.enable = true;
      pkcs11.package = pkgs.tpm2-pkcs11-esapi;
      tctiEnvironment.enable = true;
    };

    environment.sessionVariables.TPM2_PKCS11_STORE = tokenDir;
    users.users."${cfg.User}".extraGroups = [ "tss" ];

    systemd.services.tpm-device-permissions = {
      description = "Set TPM device permissions for container use";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-sysusers.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail
        for dev in /dev/tpm0 /dev/tpmrm0; do
          [ -e "$dev" ] || continue
          # Grant the local tss group rw through an ACL rather than chgrp.
          # These are the host's device nodes, and host and guest allocate
          # system GIDs independently, so taking the inode group would hand it
          # this container's tss GID and revoke the host's own tss access to
          # its TPM. An ACL entry leaves owner and group untouched, so every
          # party can add its own.
          ${pkgs.acl}/bin/setfacl -m g:tss:rw "$dev"
        done
      '';
    };
  };
}
