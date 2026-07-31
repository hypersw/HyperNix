{ config, lib, pkgs, ... }:

let
  cfg = config.hypersw.programs.rcloneSecureConfig;
  inherit (lib) mkEnableOption mkIf mkOption types;

  bootstrapServiceName = "rclone-secure-config-bootstrap";
  credentialFile = "${cfg.configDirectory}/${cfg.passwordCredentialName}.cred";

  # rclone invokes this command only when it needs to decrypt its config. The
  # password is supplied by the specific systemd service that launched rclone,
  # never by Nix, an environment variable, or a file in the user's home.
  passwordCommand = pkgs.writeShellScript "rclone-config-password-command" ''
    set -eu

    : "''${CREDENTIALS_DIRECTORY:?rclone config password requires a systemd credential}"
    credential="''${CREDENTIALS_DIRECTORY}/${cfg.passwordCredentialName}"

    if [ ! -r "$credential" ]; then
      echo "rclone config password credential is unavailable: $credential" >&2
      exit 1
    fi

    exec ${pkgs.coreutils}/bin/cat "$credential"
  '';

  bootstrap = pkgs.writeShellScript "rclone-secure-config-bootstrap" ''
    set -euo pipefail

    config_directory=${lib.escapeShellArg cfg.configDirectory}
    config_file=${lib.escapeShellArg cfg.configFile}
    credential_file=${lib.escapeShellArg credentialFile}

    ${pkgs.coreutils}/bin/mkdir -p "$config_directory"
    ${pkgs.coreutils}/bin/chmod 0700 "$config_directory"

    if [ ! -e "$credential_file" ]; then
      # Never silently replace a lost password: doing so would make an
      # existing encrypted rclone.conf permanently unreadable.
      if [ -e "$config_file" ]; then
        echo "Refusing to generate a new rclone config password: $config_file exists but $credential_file is missing" >&2
        exit 1
      fi

      tmp=$(${pkgs.coreutils}/bin/mktemp "$config_directory/.${cfg.passwordCredentialName}.XXXXXX")
      trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
      ${pkgs.coreutils}/bin/chmod 0600 "$tmp"

      # The random password flows directly from the kernel RNG into encrypted
      # credential ciphertext. It is never written as plaintext to disk.
      ${pkgs.coreutils}/bin/head -c 48 /dev/urandom \
        | ${pkgs.coreutils}/bin/base64 \
        | ${pkgs.systemd}/bin/systemd-creds encrypt --user --with-key=tpm2 \
            --name=${lib.escapeShellArg cfg.passwordCredentialName} - "$tmp"

      ${pkgs.coreutils}/bin/mv -f "$tmp" "$credential_file"
      trap - EXIT
    fi
  '';

  setupCommand = pkgs.writeShellScriptBin "rclone-secure-config" ''
    set -euo pipefail

    ${pkgs.systemd}/bin/systemctl --user start ${bootstrapServiceName}.service

    exec ${pkgs.systemd}/bin/systemd-run --user --pty --wait --collect \
      --property=LoadCredentialEncrypted=${cfg.passwordCredentialName}:${credentialFile} \
      ${pkgs.rclone}/bin/rclone \
        --config=${lib.escapeShellArg cfg.configFile} \
        --password-command=${lib.escapeShellArg passwordCommand} \
        config "$@"
  '';

  mkMountService = name: mount:
    let
      mountPoint = mount.mountPoint;
      cacheDirectory = "${cfg.cacheDirectory}/${name}";
      mountArgs = lib.concatStringsSep " " (map lib.escapeShellArg mount.extraArgs);
    in {
      description = "rclone mount ${name} (${mount.remote}:)";
      wantedBy = [ "default.target" ];
      requires = [ "${bootstrapServiceName}.service" ];
      after = [ "network-online.target" "${bootstrapServiceName}.service" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "notify";
        LoadCredentialEncrypted = "${cfg.passwordCredentialName}:${credentialFile}";
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg mountPoint} ${lib.escapeShellArg cacheDirectory}";
        ExecStart = "${pkgs.rclone}/bin/rclone --config=${lib.escapeShellArg cfg.configFile} --password-command=${lib.escapeShellArg passwordCommand} --cache-dir=${lib.escapeShellArg cacheDirectory} mount ${lib.escapeShellArg "${mount.remote}:"} ${lib.escapeShellArg mountPoint} --vfs-cache-mode=${mount.vfsCacheMode}${lib.optionalString (mountArgs != "") " ${mountArgs}"}";
        ExecStop = "-/run/wrappers/bin/fusermount -u ${mountPoint}";
        Restart = "on-failure";
        RestartSec = "5s";
        Environment = [ "PATH=/run/wrappers/bin" ];
      };
    };
in
{
  options.hypersw.programs.rcloneSecureConfig = {
    enable = mkEnableOption "secure per-user rclone configuration and mounts";

    user = mkOption {
      type = types.str;
      description = "User that owns the persistent, encrypted rclone configuration and mounts.";
    };

    group = mkOption {
      type = types.str;
      default = cfg.user;
      defaultText = lib.literalExpression "config.hypersw.programs.rcloneSecureConfig.user";
      description = "Group that owns the rclone configuration directory.";
    };

    configDirectory = mkOption {
      type = types.str;
      default = "/home/${cfg.user}/.config/rclone";
      defaultText = lib.literalExpression ''"/home/\${config.hypersw.programs.rcloneSecureConfig.user}/.config/rclone"'';
      description = "Persistent directory for the encrypted rclone.conf and TPM-bound credential ciphertext.";
    };

    configFile = mkOption {
      type = types.str;
      default = "${cfg.configDirectory}/rclone.conf";
      defaultText = lib.literalExpression ''"\${config.hypersw.programs.rcloneSecureConfig.configDirectory}/rclone.conf"'';
      description = "Persistent rclone configuration path. It is created interactively and encrypted by rclone.";
    };

    cacheDirectory = mkOption {
      type = types.str;
      default = "/home/${cfg.user}/.cache/rclone";
      defaultText = lib.literalExpression ''"/home/\${config.hypersw.programs.rcloneSecureConfig.user}/.cache/rclone"'';
      description = "Parent directory for per-mount VFS caches.";
    };

    passwordCredentialName = mkOption {
      type = types.strMatching "[A-Za-z0-9_.-]+";
      default = "rclone-config-password";
      description = "Name of the TPM-bound systemd credential that protects the shared rclone configuration.";
    };

    passwordCommand = mkOption {
      type = types.path;
      readOnly = true;
      description = "Credential-aware executable used internally as rclone's --password-command.";
    };

    setupCommand = mkOption {
      type = types.path;
      readOnly = true;
      description = "Interactive rclone-config command that receives the config password through a transient systemd service.";
    };

    mounts = mkOption {
      default = { };
      description = "Declarative rclone FUSE mounts. Each entry becomes one systemd user service but shares this module's encrypted rclone.conf and password credential.";
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          remote = mkOption {
            type = types.str;
            default = name;
            description = "Name of the rclone remote in the shared encrypted configuration.";
          };

          mountPoint = mkOption {
            type = types.str;
            description = "Existing-or-created local directory to mount this remote into.";
          };

          vfsCacheMode = mkOption {
            type = types.enum [ "off" "minimal" "writes" "full" ];
            default = "writes";
            description = "rclone VFS cache mode for this mount.";
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = [ "--dir-cache-time=1m" ];
            description = "Additional rclone mount arguments, shell-escaped by the module.";
          };
        };
      }));
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.rclone setupCommand ];

    # Supplies the setuid fusermount/fusermount3 wrappers rclone mount needs.
    # A container still needs IsFuse on its host-side declaration to expose
    # /dev/fuse through the namespace boundary.
    programs.fuse.enable = true;

    systemd.tmpfiles.rules = [
      "d ${cfg.configDirectory} 0700 ${cfg.user} ${cfg.group} -"
      "d ${cfg.cacheDirectory} 0700 ${cfg.user} ${cfg.group} -"
    ];

    systemd.user.services = {
      ${bootstrapServiceName} = {
        description = "Create the TPM-bound rclone configuration password when absent";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = bootstrap;
        };
      };
    } // lib.mapAttrs' (name: mount: {
      name = "rclone-mount-${name}";
      value = mkMountService name mount;
    }) cfg.mounts;

    hypersw.programs.rcloneSecureConfig.passwordCommand = passwordCommand;
    hypersw.programs.rcloneSecureConfig.setupCommand = setupCommand;

    assertions = [
      {
        assertion = cfg.user != "";
        message = "hypersw.programs.rcloneSecureConfig.user must be set when enabled.";
      }
    ];
  };
}
