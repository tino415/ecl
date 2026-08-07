# ecl -- call allowlisted functions in a running Emacs daemon.
# Installs only the shell client (bin/ecl); Emacs consumes the elisp
# straight from git via use-package :vc (package-vc), so one .emacs
# works on nix and non-nix systems alike.
{ pkgs ? import <nixpkgs> { } }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "ecl";
  version = "0.2.0";
  src = ./.;
  dontBuild = true;
  installPhase = ''
    install -Dm755 bin/ecl $out/bin/ecl
  '';
}
