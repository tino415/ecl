# ecl -- call allowlisted functions in a running Emacs daemon.
# Installs the shell client (bin/ecl) and the elisp (ecl.el, ecl-org.el)
# into share/emacs/site-lisp; add that dir to load-path in your init.
{ pkgs ? import <nixpkgs> { } }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "ecl";
  version = "0.1.0";
  src = ./.;
  dontBuild = true;
  installPhase = ''
    install -Dm755 bin/ecl $out/bin/ecl
    install -Dm644 ecl.el ecl-org.el -t $out/share/emacs/site-lisp
  '';
}
