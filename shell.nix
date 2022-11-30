{pkgs ? import <nixpkgs> {}}: let
  hpkgs = pkgs.haskellPackages;
  simple-smt-z3 = hpkgs.callCabal2nix "simple-smt-z3" ./Z3 {};
in
  pkgs.mkShell {
    inputsFrom = [simple-smt-z3.env];
    buildInputs = with pkgs; [cabal-install z3 ormolu];
  }
