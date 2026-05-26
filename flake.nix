{
  description = "Fastest: Generic test runner for Nix flakes";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = lib.systems.flakeExposed;
      eachSystem = lib.genAttrs systems;
      mkOutputs = system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in import ./default.nix { inherit pkgs; };
    in
    {
      packages = eachSystem (system:
        let out = mkOutputs system;
        in { fastest = out.fastest; default = out.fastest; }
      );

      devShells = eachSystem (system:
        let out = mkOutputs system;
        in { default = out.devShell; }
      );
    };
}
