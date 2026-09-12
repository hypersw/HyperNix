# askpass-safe — SSH_ASKPASS/SUDO_ASKPASS prompter that cannot hang.
#
# Successor to ./../SshAskpassCredentialHelper: same git credential-cache
# memoization and the same closefrom3 discipline, but the prompt itself is a
# ladder of time-bounded tiers (tty → zenity → FIFO) instead of one
# unconditional zenity call. See askpass-safe.sh's header for the failure
# mode that motivates it.
#
# Unlike its sibling, configuration is substituted into the script at build
# time rather than injected by a makeWrapper `--set` wrapper. Same goal — no
# global env pollution, no cross-flake name collisions — reached more
# directly: there is no env var to namespace, and the effective settings are
# readable in the built script. ASKPASS_SAFE_* still override at runtime.
{ pkgs
, closefrom3
, order        ? "tty,gui,fifo"  # tiers to try, in order
, cacheTimeout ? 3600            # credential-cache lifetime, seconds
, perTokenPin  ? false           # true: one cache slot per PIN prompt
, xTimeout     ? 2               # cap on the X11 handshake probe, seconds
, guiTimeout   ? 120             # cap on an unanswered zenity dialog, seconds
, fifoTimeout  ? 300             # cap on an unanswered FIFO prompt, seconds
, fixDisplay   ? true            # on bootstrap, move off a dead DISPLAY
}:
let
  src = pkgs.replaceVars ./askpass-safe.sh {
    git        = "${pkgs.git}/bin/git";
    zenity     = "${pkgs.zenity}/bin/zenity";
    xdpyinfo   = "${pkgs.xdpyinfo or pkgs.xorg.xdpyinfo}/bin/xdpyinfo";
    closefrom3 = "${closefrom3}/bin/closefrom3";

    order        = order;
    cacheTimeout = toString cacheTimeout;
    perTokenPin  = if perTokenPin then "1" else "";
    xTimeout     = toString xTimeout;
    guiTimeout   = toString guiTimeout;
    fifoTimeout  = toString fifoTimeout;
    fixDisplay   = if fixDisplay then "1" else "0";
  };
in
pkgs.runCommand "askpass-safe" { } ''
  install -Dm755 ${src} $out/bin/askpass-safe
  # Catch a substitution that broke the syntax at build time, not at the
  # moment ssh needs a passphrase.
  ${pkgs.bash}/bin/bash -n $out/bin/askpass-safe
''
