{
  description = "Fastest smoke tests (flake mode)";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    {
      tests.smoke = {
        test-pass = {
          expr = 1 + 1;
          expected = 2;
        };

        test-string = {
          expr = "hello" + "world";
          expected = "helloworld";
        };

        test-list = {
          expr = [ 1 2 3 ];
          expected = [ 1 2 3 ];
        };

        test-nested.test-inner = {
          expr = "nested";
          expected = "nested";
        };
      };
    };
}
