{ pkgs
, packages ? []
, firefoxExtensions ? []
, resolution ? null
, scale ? 1
, firefoxPolicies ? {}
, disableAudio ? true
, extraFiles ? {}
, network ? { mode = "networkmanager"; }
}:
let
  lib = pkgs.lib;
  validIp = ip: builtins.isString ip && (let
    parts = lib.splitString "." ip;
  in builtins.length parts == 4 && lib.all (p:
    builtins.match "(0|[1-9][0-9]{0,2})" p != null && lib.toInt p <= 255
  ) parts);
  validCidr = address: builtins.isString address && (let
    parts = lib.splitString "/" address;
  in builtins.length parts == 2 && validIp (builtins.elemAt parts 0)
    && builtins.match "(0|[1-9][0-9]?)" (builtins.elemAt parts 1) != null
    && lib.toInt (builtins.elemAt parts 1) <= 32);
  validNetwork = builtins.isAttrs network && (network.mode or "") == "networkmanager"
    || (builtins.isAttrs network && (network.mode or "") == "static"
      && builtins.isString (network.interface or null)
      && builtins.match "[a-zA-Z0-9_.-]{1,15}" network.interface != null
      && validCidr (network.address or null)
      && ((network.gateway or null) == null || validIp network.gateway));
  validPackage = p: builtins.isString p && builtins.match "[a-z0-9][a-z0-9+.:/-]*" p != null;
  validExtension = e: builtins.isAttrs e && e ? id && e ? url
    && builtins.isString e.id && e.id != ""
    && builtins.isString e.url && lib.hasPrefix "https://" e.url;
  indexedExtensions = lib.imap0 (i: e: e // { file = "extension-${toString i}.xpi"; }) firefoxExtensions;
  extensionPolicies = builtins.listToAttrs (map (e: {
    name = e.id;
    value = {
      installation_mode = "normal_installed";
      install_url = "file:///usr/share/ubuntu-live/firefox-extensions/${e.file}";
    };
  }) indexedExtensions);
  defaults = {
    SkipTermsOfUse = true;
    DisableTelemetry = true;
    DisableFirefoxStudies = true;
    Preferences = {
      "browser.crashReports.unsubmittedCheck.enabled" = false;
      "browser.crashReports.unsubmittedCheck.autoSubmit2" = false;
      "browser.tabs.crashReporting.includeURL" = false;
      "browser.tabs.crashReporting.sendReport" = false;
    };
    ExtensionSettings = extensionPolicies;
  };
  configFile = pkgs.writeText "ubuntu-live-config.json" (builtins.toJSON {
    inherit packages resolution scale disableAudio network;
    extensions = indexedExtensions;
    policies = lib.recursiveUpdate defaults firefoxPolicies;
  });
  validTarget = p: lib.hasPrefix "/" p && p != "/"
    && !(lib.hasInfix "/../" "${p}/") && !(lib.hasInfix "//" p);
  files = pkgs.runCommand "ubuntu-live-extra-files" {} (lib.concatStringsSep "\n" (
    lib.mapAttrsToList (target: source: ''
      mkdir -p "$out$(dirname ${lib.escapeShellArg target})"
      cp -rL -- ${lib.escapeShellArg (toString source)} "$out"${lib.escapeShellArg target}
    '') extraFiles
  ) + ''
    mkdir -p "$out"
  '');
in
assert lib.assertMsg (lib.all validPackage packages) "Invalid Ubuntu package name";
assert lib.assertMsg validNetwork "network must select networkmanager, or static with interface, IPv4 address/prefix and optional IPv4 gateway";
assert lib.assertMsg (lib.all validExtension firefoxExtensions) "Extensions require an id and HTTPS url";
assert lib.assertMsg (builtins.length (lib.unique (map (e: e.id) firefoxExtensions)) == builtins.length firefoxExtensions) "Duplicate Firefox extension ID";
assert lib.assertMsg (resolution == null || (builtins.isString resolution && builtins.match "[1-9][0-9]{2,4}x[1-9][0-9]{2,4}" resolution != null)) "Invalid display resolution";
assert lib.assertMsg ((scale == 1 || scale == 2) && (scale == 1 || resolution != null)) "Scale must be 1 or 2; scale 2 requires a resolution";
assert lib.assertMsg (lib.all validTarget (builtins.attrNames extraFiles)) "Extra file targets must be absolute paths without .. components";
pkgs.writeShellApplication {
  name = "build-ubuntu-live";
  runtimeInputs = [ pkgs.podman pkgs.coreutils ];
  text = ''
    export LIVE_SOURCE=${./.}
    export LIVE_CONFIG=${configFile}
    export LIVE_EXTRA_FILES=${files}
    export LIVE_RESOLUTION=${if resolution == null then "auto" else resolution}
    export LIVE_SCALE=${toString scale}
    exec bash "$LIVE_SOURCE/build.sh" "$@"
  '';
}
