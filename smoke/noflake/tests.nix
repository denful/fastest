# Fastest smoke tests (non-flake mode)
#
# Run with: fastest --file . -A tests.smoke
#
{
  tests = {
    smoke = {
      test-pass = {
        expr = 2 + 2;
        expected = 4;
      };

      test-bool = {
        expr = true;
        expected = true;
      };

      test-attr = {
        expr = { a = 1; }.a;
        expected = 1;
      };

      test-nested.test-inner = {
        expr = "noflake-works";
        expected = "noflake-works";
      };
    };
  };
}
