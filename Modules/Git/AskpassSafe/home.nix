{ config, lib, pkgs, ... }:
let
  cfg = config.programs.askpass-safe;

  closefrom3 = import ../../../Util/CloseFrom3/package.nix { inherit pkgs; };
  package = import ../../../Git/AskpassSafe/package.nix {
    inherit pkgs closefrom3;
    inherit (cfg) order cacheTimeout perTokenPin xTimeout guiTimeout fifoTimeout fixDisplay;
  };
  bin = "${package}/bin/askpass-safe";
in
{
  # An on-call tool, not a replacement for the container's askpass.
  #
  # Ordinary sessions in this container reach a live X display and the plain
  # zenity helper works, so enabling this must change nothing about them. It
  # earns its keep only where the display is a black hole - an xpra session, a
  # machinectl login that inherited a stale DISPLAY, an orphaned ssh -X
  # forward - and there you apply it to the one shell that needs it:
  #
  #   . ~/.nix-profile/bin/askpass-safe
  #
  # Sourcing exports SSH_ASKPASS/SUDO_ASKPASS into that shell and moves it off
  # a dead DISPLAY; everything it touches dies with the shell. It works in a
  # non-interactive shell too (a script, a wrapped job), where it stays silent
  # instead of printing the summary.
  options.programs.askpass-safe = {
    enable = lib.mkEnableOption ''
      askpass-safe, an on-call SSH_ASKPASS/SUDO_ASKPASS prompter with a
      tty/zenity/FIFO ladder and git credential-cache. Enabling only puts it
      on PATH to be sourced when a session needs it; it changes nothing about
      sessions that do not
    '';

    autoInstall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install it for every session instead of on call: export
        SSH_ASKPASS/SUDO_ASKPASS through `home.sessionVariables` and run the
        DISPLAY repair from bash's init.

        Off by default, because a session whose display works is better served
        by the container's own askpass, and because a prompter that has to be
        reached for deliberately cannot silently take over prompts that were
        working. Turn it on for a host where the display is unreliable often
        enough that reaching for it every time is the greater nuisance.
      '';
    };

    order = lib.mkOption {
      type = lib.types.str;
      default = "tty,gui,fifo";
      description = ''
        Comma-separated prompt tiers, tried left to right. `tty` prompts on
        /dev/tty, `gui` opens zenity once a bounded probe proves the X display
        answers, `fifo` announces on the user's terminals and waits on a FIFO.
        tty-first keeps prompts in the terminal, which is what you want in the
        sessions this tool exists for; put `gui` first for a desktop session.
      '';
    };

    cacheTimeout = lib.mkOption {
      type = lib.types.int;
      default = 3600;
      description = "Cache timeout in seconds";
    };

    perTokenPin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Cache PINs per token (true) or use one shared PIN for all tokens (false)";
    };

    xTimeout = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = ''
        Seconds to wait for the X11 handshake before treating the display as
        dead. A dead display accepts the connection and never answers, so this
        cap - not the connect - is what detects it.
      '';
    };

    guiTimeout = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "Seconds an unanswered zenity dialog stays up before the next tier is tried";
    };

    fifoTimeout = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Seconds to wait for an answer written into the FIFO";
    };

    fixDisplay = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When applied to a shell, probe DISPLAY and switch to a live one if the
        inherited display is a black hole. Under xpra + machinectl several
        stale displays can be present at once.
      '';
    };

    intro = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Print a short summary when applied to an interactive shell - what it
        bound, and what it concluded about the display. Non-interactive shells
        are silent regardless.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # The whole of the default install: on PATH, so it can be run as a
      # prompter and sourced by a shell that needs it. No session variables,
      # no shell init, nothing that acts on a session that never asks.
      home.packages = [ package ];
    })

    (lib.mkIf (cfg.enable && cfg.autoInstall) {
      home.sessionVariables = {
        SSH_ASKPASS = bin;
        SUDO_ASKPASS = bin;
        # "prefer" routes prompts through the ladder even when a tty exists, so
        # the cache is consulted and the tty tier can answer in-terminal.
        SSH_ASKPASS_REQUIRE = "prefer";
      };

      # The DISPLAY repair is per-shell, so it cannot come from sessionVariables.
      programs.bash.initExtra = ''
        eval "$(${bin} --bootstrap-env${lib.optionalString cfg.intro " --intro"})"
      '';
    })
  ];
}
