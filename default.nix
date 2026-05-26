{ pkgs ? import <nixpkgs> {} }:
{
  fastest = pkgs.writeShellApplication {
    name = "fastest";
    text = builtins.readFile ./fastest.bash;
    runtimeInputs = with pkgs; [
      nix
      jq
      nix-eval-jobs
      nix-output-monitor
    ];
  };

  devShell = pkgs.mkShell {
    buildInputs = with pkgs; [
      nix
      jq
      nix-eval-jobs
      shellcheck
    ];
  };
}
