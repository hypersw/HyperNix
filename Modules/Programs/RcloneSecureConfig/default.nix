{ config, lib, pkgs, ... }:

let
  cfg = config.hypersw.programs.rcloneSecureConfig;
  inherit (lib) mkEnableOption mkIf mkOption types;

  bootstrapServiceName = name: "rclone-secure-config-bootstrap-${name}";

  credentialFile = mount:
    "${cfg.configDirectory}/${mount.passwordCredentialName}.cred";

  # rclone invokes this command only when it needs to decrypt its config. The
  # password is supplied by the specific systemd service that launched rclone,
  # never by Nix, an environment variable, or a file in the user's home.
  passwordCommand = pkgs.writeShellScript "rclone-config-password-command" ''
    set -eu

    : "''${CREDENTIALS_DIRECTORY:?rclone config password requires a systemd credential}"
    credential_name="''${RCLONE_CONFIG_PASSWORD_CREDENTIAL:?rclone config password credential name is required}"
    credential="''${CREDENTIALS_DIRECTORY}/$credential_name"

    if [ ! -r "$credential" ]; then
      echo "rclone config password credential is unavailable: $credential" >&2
      exit 1
    fi

    exec ${pkgs.coreutils}/bin/cat "$credential"
  '';

  mkBootstrap = name: mount: pkgs.writeShellScript "rclone-secure-config-bootstrap-${name}" ''
    set -euo pipefail

    config_directory=${lib.escapeShellArg cfg.configDirectory}
    config_file=${lib.escapeShellArg mount.configFile}
    credential_file=${lib.escapeShellArg (credentialFile mount)}

    ${pkgs.coreutils}/bin/mkdir -p "$config_directory"
    ${pkgs.coreutils}/bin/chmod 0700 "$config_directory"

    if [ ! -e "$credential_file" ]; then
      # Never silently replace a lost password: doing so would make an
      # existing encrypted configuration permanently unreadable.
      if [ -e "$config_file" ]; then
        echo "Refusing to generate a new rclone config password: $config_file exists but $credential_file is missing" >&2
        exit 1
      fi

      tmp=$(${pkgs.coreutils}/bin/mktemp "$config_directory/.${mount.passwordCredentialName}.XXXXXX")
      trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
      ${pkgs.coreutils}/bin/chmod 0600 "$tmp"

      # The random password flows directly from the kernel RNG into encrypted
      # credential ciphertext. It is never written as plaintext to disk.
      ${pkgs.coreutils}/bin/head -c 48 /dev/urandom \
        | ${pkgs.coreutils}/bin/base64 \
        | ${pkgs.systemd}/bin/systemd-creds encrypt --user --with-key=host+tpm2 \
            --name=${lib.escapeShellArg mount.passwordCredentialName} - "$tmp"

      ${pkgs.coreutils}/bin/mv -f "$tmp" "$credential_file"
      trap - EXIT
    fi
  '';

  mkSetupCase = name: mount: ''
    ${lib.escapeShellArg name})
      config_file=${lib.escapeShellArg mount.configFile}
      credential_file=${lib.escapeShellArg (credentialFile mount)}
      credential_name=${lib.escapeShellArg mount.passwordCredentialName}
      bootstrap_service=${lib.escapeShellArg (bootstrapServiceName name)}
      ;;
  '';

  setupCommand = pkgs.writeShellScriptBin "rclone-secure-config" ''
    set -euo pipefail

    if [ "$#" -lt 1 ]; then
      echo "Usage: rclone-secure-config <mount> [rclone config arguments...]" >&2
      exit 2
    fi

    mount_name=$1
    shift

    case "$mount_name" in
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkSetupCase cfg.mounts)}
      *)
        echo "Unknown rclone mount: $mount_name" >&2
        exit 2
        ;;
    esac

    ${pkgs.systemd}/bin/systemctl --user start "$bootstrap_service.service"

    exec ${pkgs.systemd}/bin/systemd-run --user --pty --wait --collect \
      --property="LoadCredentialEncrypted=$credential_name:$credential_file" \
      --setenv="RCLONE_CONFIG_PASSWORD_CREDENTIAL=$credential_name" \
      ${pkgs.rclone}/bin/rclone \
        --config="$config_file" \
        --password-command=${lib.escapeShellArg passwordCommand} \
        config "$@"
  '';

  mkMountService = name: mount:
    let
      mountPoint = mount.mountPoint;
      cacheDirectory = "${cfg.cacheDirectory}/${name}";
      mountArgs = lib.concatStringsSep " " (map lib.escapeShellArg mount.extraArgs);
      bootstrapService = bootstrapServiceName name;
    in {
      description = "rclone mount ${name} (${mount.remote}:)";
      wantedBy = [ "default.target" ];
      requires = [ "${bootstrapService}.service" ];
      after = [ "network-online.target" "${bootstrapService}.service" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "notify";
        LoadCredentialEncrypted = "${mount.passwordCredentialName}:${credentialFile mount}";
        # Refuse plaintext and undecryptable configuration before rclone can
        # access this mount's OAuth token.
        ExecStartPre = [
          "${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg mountPoint} ${lib.escapeShellArg cacheDirectory}"
          "${pkgs.rclone}/bin/rclone --config=${lib.escapeShellArg mount.configFile} --password-command=${lib.escapeShellArg passwordCommand} config encryption check"
        ];
        ExecStart = "${pkgs.rclone}/bin/rclone --config=${lib.escapeShellArg mount.configFile} --password-command=${lib.escapeShellArg passwordCommand} --cache-dir=${lib.escapeShellArg cacheDirectory} mount ${lib.escapeShellArg "${mount.remote}:"} ${lib.escapeShellArg mountPoint} --vfs-cache-mode=${mount.vfsCacheMode}${lib.optionalString (mountArgs != "") " ${mountArgs}"}";
        ExecStop = "-/run/wrappers/bin/fusermount -u ${mountPoint}";
        Restart = "on-failure";
        RestartSec = "5s";
        Environment = [
          "PATH=/run/wrappers/bin"
          "RCLONE_CONFIG_PASSWORD_CREDENTIAL=${mount.passwordCredentialName}"
        ];
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
      description = "Persistent directory for per-mount encrypted rclone configurations and credential ciphertext.";
    };

    cacheDirectory = mkOption {
      type = types.str;
      default = "/home/${cfg.user}/.cache/rclone";
      defaultText = lib.literalExpression ''"/home/\${config.hypersw.programs.rcloneSecureConfig.user}/.cache/rclone"'';
      description = "Parent directory for per-mount VFS caches.";
    };

    passwordCommand = mkOption {
      type = types.path;
      readOnly = true;
      description = "Credential-aware executable used internally as rclone's --password-command.";
    };

    setupCommand = mkOption {
      type = types.path;
      readOnly = true;
      description = "Interactive rclone configuration command that selects one mount's configuration and receives its password through a transient systemd service.";
    };

    mounts = mkOption {
      default = { };
      description = "Declarative rclone FUSE mounts. Each entry has a separate encrypted configuration and password credential.";
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          remote = mkOption {
            type = types.str;
            default = name;
            description = "Name of the rclone remote in this mount's encrypted configuration.";
          };

          configFile = mkOption {
            type = types.str;
            default = "${cfg.configDirectory}/${name}.conf";
            defaultText = lib.literalExpression ''"\${config.hypersw.programs.rcloneSecureConfig.configDirectory}/<mount>.conf"'';
            description = "Persistent rclone configuration path for this mount. It is created interactively and encrypted by rclone.";
          };

          passwordCredentialName = mkOption {
            type = types.strMatching "[A-Za-z0-9_.-]+";
            default = "rclone-${name}-config-password";
            description = "Name of the TPM-backed systemd credential that protects this mount's configuration.";
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

    systemd.user.services = lib.mapAttrs' (name: mount: {
      name = bootstrapServiceName name;
      value = {
        description = "Create the TPM-backed rclone configuration password for ${name} when absent";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = mkBootstrap name mount;
        };
      };
    }) cfg.mounts // lib.mapAttrs' (name: mount: {
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
