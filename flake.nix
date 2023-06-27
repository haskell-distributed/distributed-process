{
  description = ''
  This is an implementation of Cloud Haskell, as described in
  /Towards Haskell in the Cloud/ by Jeff Epstein, Andrew Black,
  and Simon Peyton Jones
  (<http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/>),
  although some of the details are different. The precise message
  passing semantics are based on /A unified semantics for future Erlang/
  by Hans Svensson, Lars-&#xc5;ke Fredlund and Clara Benac Earle.
  '';

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    forAllSystems = function: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: function rec {
      inherit system;
      compilerVersion = "ghc945";
      pkgs = nixpkgs.legacyPackages.${system};
      hsPkgs = pkgs.haskell.packages.${compilerVersion}.override {
        overrides = hfinal: hprev: with pkgs.haskell.lib; {
          # Internal Packages
          distributed-process = hfinal.callCabal2nix "distributed-process" ./. {};

          # External Packages
          rank1dynamic = dontCheck (markUnbroken (hprev.rank1dynamic));
        };
      };
    });
  in {
    formatter = forAllSystems ({pkgs, ...}: pkgs.alejandra);

    # You can't build the servicehub package as a check because of IFD in cabal2nix
    checks = {};

    # nix develop
    devShells = forAllSystems ({hsPkgs, pkgs, ...}: {
      default = hsPkgs.shellFor {
        name = "distributed-process";
        packages = p: [
          p.distributed-process
        ];
        buildInputs = with pkgs;
          [
            hsPkgs.haskell-language-server
            hsPkgs.cabal-install
            cabal2nix
            haskellPackages.ghcid
          ];
      };
    });
  };
}
