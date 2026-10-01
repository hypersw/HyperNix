{ pkgs, ... }:
{
  programs.nix-ld-libraries = {
    enable = true;
    libraries = with pkgs; [
      # The container enables nix-ld without system libraries; portable
      # binaries need these basics when this profile is explicitly sourced.
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

      # Java AWT's X11 toolkit and font support.
      libxext
      libx11
      libxrender
      libxtst
      libxi
      freetype
      fontconfig.lib

      # Java AWT's Wayland toolkit.
      wayland # libwayland-client.so.0 and libwayland-cursor.so.0
      libxkbcommon

      icu # CoreCLR, https://aka.ms/dotnet-missing-libicu
      e2fsprogs # IDEA's FileSystemUtil$E2P calls into it
      libsecret # password storage

      libglvnd # libGL.so.1, for Toolbox Skiso

      # DotTrace on Avalonia.
      gtk3
      libsm
      libice

      glib
      pango

      # AIR desktop.
      gtk4
      graphene

      pcre2 # Rider RemDev

      # Rider JCEF's native cef_server and libcef.so.
      nss
      nspr
      atk
      at-spi2-atk
      at-spi2-core
      dbus
      cups
      libxcomposite
      libxdamage
      libxfixes
      libxrandr
      libxcb
      libgbm
      expat
      cairo
      alsa-lib
    ];
  };
}