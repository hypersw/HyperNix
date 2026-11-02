{ config, lib, pkgs, ... }:
let
  cfg = config.services.git-fetch-all;

  # One token per line, each with what it hands to the script.
  args = [
    "-NoProfile"
    "-NonInteractive"
    "-File" cfg.script
    "-Root" cfg.root                                          # folder of the store and the two-letter copies
    "-Store" cfg.store                                        # store owner repo under the root
    "-RepackThreshold" cfg.repackThreshold                    # routine tier, every run
    "-DailyRepackThreshold" cfg.dailyRepackThreshold          # daily tier
    "-DailyWindowStartUtc" (toString cfg.dailyWindowStartUtc) # daily tier window, first UTC hour
    "-DailyWindowEndUtc" (toString cfg.dailyWindowEndUtc)     # daily tier window, end UTC hour (exclusive)
  ] ++ lib.optionals (cfg.logDir != null) [ "-LogDir" cfg.logDir ];
in
{
  # The scheduled half of a partial-clone store shared by many working copies:
  # the store owner repo holds the objects, every two-letter sibling links its
  # .git/objects to it. Each run fetches the store first, writes the shared
  # commit-graph, fetches the copies, then repacks the store in a size tier.
  #
  # The job itself is Git.FetchAll.ps1 from the user's scripts repo, the same
  # file the Windows scheduled task runs, so it is referenced in place rather
  # than copied into the store. The unit inherits the user manager's
  # environment: git, nix and ssh come from its PATH, and the TPM PKCS#11 store
  # from TPM2_PKCS11_STORE, so the SSH key of the remote must work without a PIN
  # (see Git/TpmSshSetup.md, Option D).
  options.services.git-fetch-all = {
    enable = lib.mkEnableOption ''
      a systemd user timer that fetches a shared partial-clone store and its
      working copies, writes the commit-graph and repacks the store
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.powershell;
      defaultText = lib.literalExpression "pkgs.powershell";
      description = "The pwsh that runs the script.";
    };

    script = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Sync.WScripts/Git.FetchAll.ps1";
      description = "Path of Git.FetchAll.ps1, used in place.";
    };

    root = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Projects";
      description = "The folder that holds the store owner and the two-letter copies.";
    };

    store = lib.mkOption {
      type = lib.types.str;
      default = "Void";
      description = "Name of the store owner repo under the root.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "*:0/10";
      description = "systemd OnCalendar expression for the runs.";
    };

    repackThreshold = lib.mkOption {
      type = lib.types.str;
      default = "32M";
      description = "Repack tier of every run: packs below it are merged, bigger ones kept.";
    };

    dailyRepackThreshold = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      description = "Repack tier of the one daily run, which folds the routine tier into the dust pack.";
    };

    dailyWindowStartUtc = lib.mkOption {
      type = lib.types.ints.between 0 23;
      default = 5;
      description = "First UTC hour in which the daily tier may run.";
    };

    dailyWindowEndUtc = lib.mkOption {
      type = lib.types.ints.between 1 24;
      default = 7;
      description = "UTC hour at which the daily window closes.";
    };

    logDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Folder for the per-tier repack logs; null keeps the script's default, the temp folder.";
    };

    timeout = lib.mkOption {
      type = lib.types.str;
      default = "1h";
      description = "Longest a run may take before systemd stops it.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.git-fetch-all = {
      Unit.Description = "Fetch the shared git store and its working copies, write the commit-graph, repack";
      Service = {
        # A timer never starts a oneshot that is still running, so overlapping runs cannot happen.
        Type = "oneshot";
        ExecStart = "${cfg.package}/bin/pwsh ${lib.escapeShellArgs args}";
        TimeoutStartSec = cfg.timeout;
        # ssh must never put up a PIN dialog for another token from a background job.
        Environment = [ "SSH_ASKPASS_REQUIRE=never" ];
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    systemd.user.timers.git-fetch-all = {
      Unit.Description = "Run git-fetch-all periodically";
      Timer = {
        OnCalendar = cfg.interval;
        # Catch up a run missed while the machine was off.
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
