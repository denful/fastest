# Fastest: Fast test runner that does 90% of nix-unit.

`fastest` was originally created for [Den](https://github.com/denful/den) as `ci-fast.bash` by [@sini](https://github.com/sini).

It uses `nix-eval-jobs` for parallel `nix-unit`-like test execution. Unlike `nix-unit`, `fastest` is designed for speed, because
many Den integration tests use real NixOS evaluations; this parallel execution drops some nix-unit features: No error diff, No expect-throws.

This test harness work for both Nix flakes and non-flake `.nix` files.
By default, falls back to `nix-unit` for test traces when a single test is specified. Controllable via `--nix-unit`.

## Features

- **Parallel execution**: `nix-eval-jobs` runs tests across multiple workers
- **Flake mode**: Test Nix flakes with `--flake <path or path#tests>`
- **File mode**: Test raw `.nix` files with `--file <path> -A <attr>`
- **Optional suite**: Run all tests by omitting suite name, or specify suite for subset
- **Individual test traces**: Falls back to `nix-unit` for debugging (configurable via `--nix-unit`)
- **Auto-detected system**: Detects current system (can override with `-s`)
- **Configurable parallelism**: Default 8 workers, 2GB memory per worker
- **Max parallelism mode**: Use all CPU cores with unlimited memory (`-P`)
- **Environment variable overrides**: Configure via env vars
- **Backward compatible**: Positional arguments still work

## Installation

```bash
nix run github:denful/fastest#fastest -- --help
```

Or build locally:

```bash
nix build ./vic/fastest#fastest
./result/bin/fastest --help
```

## Usage

### Flake Mode

Test a Nix flake's test suites (suite is optional):

```bash
# Run specific suite
fastest --flake ./templates/ci#tests nested-aspects

# Run all tests (no suite specified)
fastest --flake ./templates/ci#tests

# Run specific test with traces
fastest --flake ./templates/ci#tests nested-aspects.test-direct-nesting-basic

# Via nix run
nix run ./fastest#fastest -- --flake ./templates/ci#tests smoke
```

**Flake reference format:**
- `path#tests` - Evaluates `tests` attribute (required for test discovery)
- `path#tests suite` - Run specific test suite
- `path#tests` alone - Run all tests
- Omitting `#tests` suffix adds it automatically

### File Mode

Test raw `.nix` files:

```bash
# File must export tests under an attribute
fastest --file ./tests.nix -A mysuites.smoke

# Example: test.nix with structure { mysuites.smoke.test-name = { expr = ...; expected = ...; }; }
```

### Options

```
-j, --workers N              Parallel workers (default: 8, max: 8)
                             Env: FASTEST_WORKERS

--max-memory-size N          Memory per worker in MiB (default: 2048)
                             Env: FASTEST_MAX_MEMORY

-P, --max-parallelism        Use all CPU cores, unlimited memory
                             Env: FASTEST_MAX_PARALLELISM=1

-s, --system SYSTEM          Target system (default: auto-detected)

-q, --quiet                  Suppress progress output
                             Env: FASTEST_QUIET=1

--show-trace                 Show Nix evaluation traces

--override-input KEY VAL     Override Nix input (repeatable)

--nix-unit auto|never|always  nix-unit usage mode (default: auto)
                              auto  = use nix-unit only for single-test traces
                              never = always use nix-eval-jobs (no traces)
                              always = force nix-unit for all runs (full traces, slower)

--option KEY VAL             Pass nix option (repeatable)

-h, --help                   Show help and env vars
```

## Examples

```bash
# Run specific suite
fastest --flake ./myflake#tests smoke

# Run all tests (no suite specified)
fastest --flake ./myflake#tests

# With custom parallelism
fastest -j 4 --flake ./myflake#tests smoke

# Maximum parallelism (all CPU cores)
fastest -P --flake ./myflake#tests smoke

# Via env vars
FASTEST_WORKERS=16 FASTEST_QUIET=1 fastest --flake ./myflake#tests smoke

# File mode (specific suite)
fastest --file ./smoke/noflake/tests.nix -A tests smoke

# File mode (all tests in attribute)
fastest --file ./smoke/noflake/tests.nix -A tests

# Individual test with traces
fastest --flake ./myflake#tests nested-aspects.test-xyz

# With Nix overrides (useful for flakes that depend on other flakes)
fastest --override-input den . --flake ./templates/ci#tests deadbugs

# Auto-detected system (no -s needed)
fastest --flake ./myflake#tests smoke

# Override system if needed
fastest -s aarch64-darwin --flake ./myflake#tests smoke
```

## How It Works

### Flake Mode (`--flake`)

1. Uses `nix-eval-jobs` to discover and run tests in parallel
2. Flake must export `.tests` attribute as a set of test suites
3. Optionally filter by suite name (e.g., `tests.smoke`), or run all tests
4. Each test is a set with `expr` and `expected` keys
5. Workers are capped at 8 (default) to prevent OOM
6. On individual test request, falls back to `nix-unit` for full traces (unless `--nix-unit never`)
7. System is auto-detected (can override with `-s/--system`)

### File Mode (`--file <path> -A <attr>`)

1. Uses `nix eval --file` to load `.nix` file
2. Evaluates the given attribute path
3. Uses jq to recursively process tests
4. Compares `expr == expected` for each test
5. Works with any `.nix` file exporting a test structure

### Parallelism

- **Default**: 8 workers, 2GB memory per worker (prevents OOM on infinite recursion)
- **Custom**: `-j N` to set workers, `--max-memory-size M` for memory
- **Max parallelism**: `-P` uses all CPU cores with unlimited memory per worker

## Environment Variables

```
FASTEST_WORKERS          Number of parallel workers (default: 8)
FASTEST_MAX_MEMORY       Memory per worker in MiB (default: 2048)
FASTEST_MAX_PARALLELISM  Enable max parallelism mode (1 = on, 0 = off)
FASTEST_QUIET            Suppress progress output (1 = on, 0 = off)
```

Examples:

```bash
# Run with 16 workers
FASTEST_WORKERS=16 fastest --flake ./myflake smoke

# Max parallelism + quiet
FASTEST_MAX_PARALLELISM=1 FASTEST_QUIET=1 fastest --flake ./myflake smoke
```

## Test Structure

### Flake tests

```nix
{
  outputs = { ... }: {
    tests.smoke = {
      test-pass = {
        expr = 1 + 1;
        expected = 2;
      };
      
      test-nested.test-inner = {
        expr = "hello";
        expected = "hello";
      };
    };
  };
}
```

### File tests

```nix
# tests.nix
{
  tests.smoke = {
    test-add = {
      expr = 1 + 1;
      expected = 2;
    };
    
    test-string = {
      expr = "world";
      expected = "world";
    };
  };
}

# Run with: fastest --file ./tests.nix -A tests.smoke
```

## Implementation

- **fastest.bash**: Main test runner script
  - Parses flags, env vars, positional args
  - Delegates to `nix-eval-jobs` (flake mode) or jq (file mode)
  - Configurable `nix-unit` usage via `--nix-unit auto|never|always`
  - Formats output consistently across modes

- **flake.nix**: Exposes app `fastest`
  - Uses `writeShellApplication` (includes shellcheck)
  - Provides `devShell` with required tools

- **default.nix**: Wraps `fastest.bash` for `nix-build`

## Testing

### Smoke Tests (Local)

```bash
just smoke-test    # Run local smoke tests (flake + file mode)
just ci-env        # Test with env vars set
just ci-trace      # Test individual test with traces
```

### Den Integration Tests

```bash
just den-smoke-test       # Test against remote den CI flake (single test)
just den-deadbugs-test    # Test den's deadbugs suite (13 tests)
just den-all-tests        # Run ALL den tests (829 tests, slow!)
```

### Full Test Suite

```bash
just ci            # Run all tests (smoke + den integration)
```
