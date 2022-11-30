{
  description = "Build environment based on callCabal2nix";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      hpkgs = pkgs.haskellPackages;
      simple-smt-z3 = hpkgs.callCabal2nix "simple-smt-z3" ./Z3 {};
      simple-smt = hpkgs.callCabal2nix "simple-smt" ./. {};
    in {
      formatter = pkgs.alejandra;
      devShells = let
        buildInputs = with pkgs; [cabal-install z3 haskell-language-server ormolu];
      in {
        default = pkgs.mkShell {
          inputsFrom = [simple-smt.env];
          inherit buildInputs;
        };
        z3 = pkgs.mkShell {
          inputsFrom = [simple-smt-z3.env];
          inherit buildInputs;
        };
      };
    });
}
