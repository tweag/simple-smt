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
    with flake-utils.lib;
      eachSystem [system.x86_64-linux] (system: let
        pkgs = nixpkgs.legacyPackages.${system};
        hpkgs = pkgs.haskellPackages;
        simple-smt = hpkgs.callCabal2nix "simple-smt" ./. {};
        simple-smt-tests = hpkgs.callCabal2nix "simple-smt-tests" ./tests {};
        simple-smt-z3 = hpkgs.callCabal2nix "simple-smt-z3" ./Z3 {
          inherit simple-smt-tests;
        };
      in {
        formatter = pkgs.alejandra;

        devShells = {
          default = hpkgs.shellFor {
            packages = p: [
              simple-smt
              simple-smt-tests
              simple-smt-z3
            ];

            withHoogle = true;

            buildInputs =
              (with hpkgs; [
                cabal-install
                hlint
                haskell-language-server
              ])
              ++ [pkgs.z3];

            ## Needed by the haskell-language-server
            shellHook = ''
              export LD_LIBRARY_PATH="${pkgs.z3.lib}/lib:''${LD_LIBRARY_PATH:+:}"
            '';
          };
        };
      });
}
