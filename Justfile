#!/usr/bin/env just --justfile

# Fastest CI runner - smoke tests

set shell := ["bash", "-c"]

help:
  just -l

ci:
  just smoke-test
  just den-smoke-test
  just den-deadbugs-test

# Run fastest CLI smoke tests (flake + file modes)
smoke-test:
  @echo "Testing flake mode..."
  bash ./fastest.bash --flake ./smoke/flake#tests smoke
  @echo
  @echo "Testing file mode (raw .nix file)..."
  bash ./fastest.bash --file ./smoke/noflake/tests.nix -A tests smoke
  @echo
  @echo "✅ All smoke tests passed (flake + file modes)!"

# Run with env vars set
ci-env:
  FASTEST_WORKERS=2 FASTEST_QUIET=0 bash ./fastest.bash --flake ./smoke/flake#tests smoke

# Run single test with traces
ci-trace:
  bash ./fastest.bash --flake ./smoke/flake#tests --show-trace smoke.test-pass

# Show help
help-fastest:
  bash ./fastest.bash --help

# Test via nix run against remote den CI flake
den-smoke-test *args:
  nix run . -- --flake github:denful/den?dir=templates/ci#tests new {{args}}

# Smoke test with den override (needed for templates/ci)
den-deadbugs-test *args:
  nix run . -- --flake github:denful/den?dir=templates/ci#tests --override-input den github:denful/den deadbugs {{args}}

# Run ALL den CI tests (evaluates all test suites)
den-all-tests *args:
  nix run . -- --flake github:denful/den?dir=templates/ci#tests --override-input den github:denful/den {{args}}

