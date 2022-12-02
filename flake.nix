{
  inputs.flake-utils.url = github:numtide/flake-utils;

  nixConfig = {
    # Needed by callCabal2nix
    allow-import-from-derivation = true;
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachSystem ["x86_64-linux"] (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      hpkgs = pkgs.haskellPackages;
      simple-smt = hpkgs.callCabal2nix "simple-smt" ./. {};
      simple-smt-z3 = hpkgs.callCabal2nix "simple-smt-z3" ./Z3 {};
    in {
      formatter = pkgs.alejandra;
      devShells = {
        default = hpkgs.shellFor {
          packages = p: [
            simple-smt
            ## TODO fails on the import of simple-smt-tests
            ## Should simple-smt-tests be declared as a library?
            # simple-smt-z3
          ];
          withHoogle = true;
          buildInputs =
            (with hpkgs; [
              cabal-install
              hlint
              haskell-language-server
            ])
            ++ [pkgs.z3];
        };
      };
    });
}
