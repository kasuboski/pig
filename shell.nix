{ pkgs ? import <nixpkgs> {} }:

let
  # OTP's configure expects OpenSSL headers and libraries below one prefix,
  # while Nixpkgs splits them into separate outputs.
  opensslForOtp = pkgs.symlinkJoin {
    name = "openssl-for-otp";
    paths = [ pkgs.openssl.out pkgs.openssl.dev ];
  };
in
pkgs.mkShell {
  packages = with pkgs; [
    autoconf
    gcc
    gnumake
    ncurses
    opensslForOtp
    perl
    pkg-config
    python3
  ];

  # Keep mise's kerl-managed Erlang build headless and point configure at the
  # combined Nix OpenSSL prefix so crypto/ssl/ssh are included.
  KERL_CONFIGURE_OPTIONS =
    "--without-javac --without-wx --with-ssl=${opensslForOtp}";

  # NixOS makes mise default to compiling Node from source. This project only
  # needs the official binary, which works when NixOS's nix-ld is enabled.
  MISE_NODE_COMPILE = "false";
}
