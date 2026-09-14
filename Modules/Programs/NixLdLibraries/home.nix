{ config, lib, pkgs, ... }:
let
  cfg = config.programs.nix-ld-libraries;

  userLibraries = pkgs.buildEnv {
    name = "nix-ld-user-libraries";
    pathsToLink = [ "/lib" ];
    paths = map lib.getLib cfg.libraries;
    ignoreCollisions = true;
  };

  systemLibraries = "/run/current-system/sw/share/nix-ld/lib";
in
{
  # The user half of nix-ld. The container turns the loader on
  # (`hypersw.containers.UserContainers.Guest.NixLd.Enable`, or plain
  # `programs.nix-ld.enable` elsewhere) and, in our containers, deliberately
  # no libraries at all; this decides what the binaries *this user* runs can
  # find through it.
  #
  # The split exists because a library list is a property of an application,
  # not of a machine. A list that lives in the system configuration makes
  # every user of the container carry every other user's dependencies, and
  # forces a container rebuild to add one `.so` for one program. Here it costs
  # a home-manager switch, and the natural next step is narrower still: a
  # devshell or a wrapper per project, with this profile holding only what is
  # wanted in every shell.
  #
  # TODO: this profile is the interim home for the list. The intended end
  # state is per-shell, so that a project brings its own dependencies and no
  # login shell carries all of them.
  options.programs.nix-ld-libraries = {
    enable = lib.mkEnableOption ''
      a user-scoped nix-ld library path. Requires nix-ld itself to be enabled
      in the system configuration; this decides what it resolves
    '';

    libraries = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        # The set nix-ld's own module installs system-wide. We turn that off
        # in the container so nothing is resolvable by default, which means
        # this list has to carry the basics itself: almost every foreign
        # binary wants libstdc++/libgcc, and losing them is not a subtle
        # failure but nothing starting at all.
        zlib
        zstd
        stdenv.cc.cc
        curl
        openssl
        attr
        libssh
        bzip2
        libxml2
        acl
        libsodium
        util-linux
        xz
        systemd

        # Terminal UI toolkits used by portable console programs.
        ncurses

        # Java AWT. It names these in plain errors at startup, except
        # fontconfig, which instead fails with a cryptic complaint about a
        # null header.
        libxext
        libx11
        libxrender
        libxtst
        libxi
        freetype
        fontconfig.lib

        icu # CoreCLR, https://aka.ms/dotnet-missing-libicu
        e2fsprogs # IDEA's FileSystemUtil$E2P calls into it
        libsecret # password storage

        libglvnd # libGL.so.1, for Toolbox Skiso

        # DotTrace on Avalonia: libgtk-3.so.0, libSM.so.6, libICE.so.6,
        # with libx11 already above.
        gtk3
        libsm
        libice

        # Added after Rider stopped starting once gtk3 was in the list.
        glib
        pango

        # AIR desktop: dlopen dependencies of libdesktop_gtk_x64.so that the
        # entries above do not already cover.
        gtk4
        graphene

        pcre2 # Rider RemDev
      ];
      description = ''
        Libraries to put on this user's NIX_LD_LIBRARY_PATH. The default is
        the basics nix-ld would otherwise install system-wide, plus the set
        accumulated for JetBrains tooling and other portable desktop binaries:
        IDEs and RemDev, Toolbox, DotTrace on Avalonia, AIR desktop, CoreCLR,
        and Java AWT.
      '';
    };

    inheritSystemLibraries = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Append the system nix-ld library path after this user's. Off by
        default, matching a system half that enables the loader and defines no
        libraries: there the system path holds nothing to inherit, and leaving
        it out keeps this profile the whole truth about what the user's
        binaries resolve. Turn it on for a host that does put libraries in its
        system configuration and whose users should still see them.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Home-manager's session variables are applied after the system ones, so
    # this replaces rather than extends the value NixOS set. That is the
    # intent — the system half enables the loader and defines no libraries —
    # but it is also why inheritSystemLibraries has to put the system path
    # back explicitly when a host does define some.
    home.sessionVariables.NIX_LD_LIBRARY_PATH =
      lib.concatStringsSep ":" (
        [ "${userLibraries}/lib" ]
        ++ lib.optional cfg.inheritSystemLibraries systemLibraries
      );
  };
}
