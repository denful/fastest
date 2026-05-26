{ pkgs ? import <nixpkgs> {} }:
let
  runtimeInputs = with pkgs; [
    bash
    coreutils
    jq
    nix-eval-jobs
    just
  ];
in
{
  fastest = pkgs.writeShellApplication {
    name = "fastest";
    text = builtins.readFile ./fastest.bash;
    inherit runtimeInputs;
  };

  devShell = pkgs.mkShell { buildInputs = runtimeInputs; };
}
