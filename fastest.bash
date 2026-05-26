#
# Fastest: generic test harness for any Nix flake or .nix file
#
# Usage: fastest [OPTIONS] [SUITE] [TEST]
#
# Options:
#   --flake REF              Flake reference (required unless --file)
#   --file PATH              File path (alternative to --flake, requires -A)
#   -A ATTR                  Attribute path (used with --file)
#   -j, --workers N          Parallel workers (env: FASTEST_WORKERS, default: 8)
#   --max-memory-size N      Memory per worker in MiB (env: FASTEST_MAX_MEMORY, default: 2048)
#   -P, --max-parallelism    Use all CPU cores, unlimited memory (env: FASTEST_MAX_PARALLELISM=1) per worker
#   -s, --system SYSTEM      Target system (default: x86_64-linux)
#   -q, --quiet              Suppress progress output (env: FASTEST_QUIET=1)
#   --show-trace             Show Nix evaluation traces
#   --override-input KEY VAL Override Nix input (repeatable)
#   --option KEY VAL         Pass nix option (repeatable)
#   --nix-unit auto|never|always  nix-unit usage: auto=single-test only (default), never=always eval-jobs, always=force nix-unit for all runs
#   -h, --help               Show this help
#
# Environment Variables:
#   FASTEST_WORKERS          Number of parallel workers (overridden by -j)
#   FASTEST_QUIET            Set to 1 for quiet mode (overridden by -q)
#   FASTEST_MAX_MEMORY       Memory per worker in MiB (overridden by --max-memory-size)
#
# Examples:
#   fastest --flake ./templates/ci nested-aspects
#   fastest --file ./tests.nix -A mysuites.smoke
#   fastest -j 4 -q --show-trace --flake ./templates/ci nested-aspects.test-xyz
#
set -aeuo pipefail

show_help() {
  grep '^#' "$0" | tail -n +2 | sed 's/^# //'
}

# Defaults (can be overridden by env vars and flags)
workers=${FASTEST_WORKERS:-8}
max_memory=${FASTEST_MAX_MEMORY:-2048}
max_parallelism=${FASTEST_MAX_PARALLELISM:-0}
system=$(nix-instantiate --eval --raw -E 'builtins.currentSystem' 2>/dev/null || echo 'x86_64-linux')
quiet=${FASTEST_QUIET:-0}
nix_unit_mode="auto"
flake_ref=""
file_path=""
attr_path=""
suite=""
test_filter=""
nix_args=()
override_args=()

# Parse flags
positional_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flake)
      flake_ref="$2"
      shift 2
      ;;
    --file)
      file_path="$2"
      shift 2
      ;;
    -A)
      attr_path="$2"
      shift 2
      ;;
    -j|--workers)
      workers="$2"
      shift 2
      ;;
    --max-memory-size)
      max_memory="$2"
      shift 2
      ;;
    -s|--system)
      system="$2"
      shift 2
      ;;
    -q|--quiet)
      quiet=1
      shift
      ;;
    -P|--max-parallelism)
      max_parallelism=1
      shift
      ;;
    --show-trace)
      nix_args+=(--show-trace)
      shift
      ;;
    --nix-unit)
      case "$2" in
        auto|never|always) nix_unit_mode="$2" ;;
        *) echo "Error: --nix-unit must be auto, never, or always" >&2; exit 1 ;;
      esac
      shift 2
      ;;
    --override-input)
      override_args+=(--override-input "$2" "$3")
      shift 3
      ;;
    --option)
      nix_args+=(--option "$2" "$3")
      shift 3
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      echo "Error: unknown option '$1'" >&2
      show_help >&2
      exit 1
      ;;
    *)
      positional_args+=("$1")
      shift
      ;;
  esac
done

# Validate: must have either flake_ref or file_path
if [[ -z "$flake_ref" && -z "$file_path" ]]; then
  echo "Error: must specify --flake or --file" >&2
  show_help >&2
  exit 1
fi

# Handle positional args for backward compat: <flake-path> [suite] [test]
if [[ ${#positional_args[@]} -gt 0 ]]; then
  # First positional: if looks like path (has / or .), assume it's flake_ref
  if [[ "${positional_args[0]}" == */* || "${positional_args[0]}" == "."* ]]; then
    if [[ -z "$flake_ref" ]]; then
      flake_ref="${positional_args[0]}"
    fi
    suite="${positional_args[1]:-}"
    test_filter="${positional_args[2]:-}"
  else
    # Otherwise assume old format: suite [test_filter]
    suite="${positional_args[0]}"
    test_filter="${positional_args[1]:-}"
  fi
fi

# Validate file mode
if [[ -n "$file_path" && -z "$attr_path" ]]; then
  echo "Error: --file requires -A attribute" >&2
  exit 1
fi

# Build test ref from flake or file
is_file_mode=0
if [[ -n "$flake_ref" ]]; then
  # Extract suite from flake ref if in format path#suite (but not if it's already path#tests)
  if [[ "$flake_ref" =~ ^(.*)#(.*)$ ]]; then
    base="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    # If suffix is "tests", already have correct ref
    if [[ "$suffix" == "tests" ]]; then
      ref="$flake_ref"
    else
      # Otherwise use suffix as suite and normalize ref to #tests
      if [[ -z "$suite" ]] && [[ -n "$suffix" ]]; then
        suite="$suffix"
      fi
      ref="${base}#tests"
    fi
  else
    ref="${flake_ref}#tests"
  fi
else
  # File mode
  is_file_mode=1
  ref="${file_path}"
  ref_attr="${attr_path#.}"  # Remove leading dot if present
fi

# Apply max parallelism if enabled
if (( max_parallelism )); then
  workers=$(nproc)
  max_memory=0
fi

# Cap workers (unless max parallelism is enabled)
if (( ! max_parallelism && workers > 8 )); then
  workers=8
fi

# Construct suite prefix/suffix for output
preSuite=""
postSuite=""
if [[ -n "$suite" ]]; then
  preSuite=".${suite}"
  postSuite="${suite}."
fi

# When specific test requested, delegate to nix-unit for traces
run_nix_unit_suite() {
  local attr="$1"
  local nix_unit_output
  if (( is_file_mode )); then
    nix_unit_output=$(nix-unit --file "${ref}" "${ref_attr}${attr}" "${nix_args[@]}" 2>&1) || true
  else
    nix_unit_output=$(nix-unit --flake "${ref}${attr}" "${nix_args[@]}" 2>&1) || true
  fi
  (( ! quiet )) && echo "$nix_unit_output" >&2 || true
  local pass fail total
  pass=$(echo "$nix_unit_output" | grep -c '^✅' || true)
  fail=$(echo "$nix_unit_output" | grep -c '^❌' || true)
  total=$(( pass + fail ))
  if [ "$fail" -eq 0 ]; then
    (( quiet )) || echo "🎉 ${pass}/${total} successful" >&2
  else
    echo "😢 ${pass}/${total} successful" >&2
    exit 1
  fi
}

if [[ -n "$test_filter" ]] && [[ "$nix_unit_mode" != "never" ]]; then
  if (( is_file_mode )); then
    nix_unit_output=$(nix-unit --file "${ref}" "${ref_attr}${preSuite}.${test_filter}" "${nix_args[@]}" 2>&1) || true
  else
    nix_unit_output=$(nix-unit --flake "${ref}${preSuite}" "${nix_args[@]}" 2>&1) || true
  fi
  if (( ! quiet )); then
    echo "$nix_unit_output" | grep -v '^[✅❌🎉😢]' | grep -v 'successful$' >&2 || true
  fi
  if echo "$nix_unit_output" | grep -q "^✅ ${test_filter}$"; then
    echo "✅ ${postSuite}${test_filter}"
    (( quiet )) || echo "🎉 1/1 successful" >&2
  else
    echo "❌ ${postSuite}${test_filter}"
    (( quiet )) || echo "😢 0/1 successful" >&2
    exit 1
  fi
  exit 0
fi

if [[ "$nix_unit_mode" == "always" ]]; then
  run_nix_unit_suite "${preSuite}"
  exit 0
fi

# never mode with test_filter: fold test into suite prefix for eval-jobs
if [[ -n "$test_filter" ]]; then
  preSuite="${preSuite}.${test_filter}"
  postSuite="${postSuite}${test_filter}."
  test_filter=""
fi

results=$(mktemp -t fastest-test-XXXXX.json)

# Evaluation: flake vs file mode
if (( is_file_mode )); then
  # FILE MODE: nix eval + jq-based test runner
  eval_json=$(nix eval --file "${ref}" "${ref_attr}${preSuite}" --json 2>/dev/null)

  # Recursively process tests and collect results
  jq -r '
    def process_tests(prefix):
      to_entries[] as $entry |
      if ($entry.value | type) == "object" then
        if ($entry.value | has("expr")) and ($entry.value | has("expected")) then
          {
            name: (if ($entry.value.expr == $entry.value.expected) then "PASS" else "FAIL" end) + "-" + (prefix as $p | if $p == "" then $entry.key else ($p + "-" + $entry.key) end | gsub("[.]"; "-")),
            attr: (prefix as $p | if $p == "" then $entry.key else ($p + "." + $entry.key) end)
          }
        else
          (prefix as $p | if $p == "" then $entry.key else ($p + "." + $entry.key) end) as $newprefix |
          ($entry.value | process_tests($newprefix))
        end
      else
        empty
      end;

    process_tests("")
  ' <<< "$eval_json" > "$results"

  # Output results
  jq -r 'select(.name != null and (.name | startswith("PASS-"))) | "✅ '"${postSuite}"'" + .attr' "$results"
else
  # FLAKE MODE: nix-eval-jobs for parallel evaluation
  eval_args=(
    --flake "${ref}${preSuite}"
    --workers "$workers"
    --force-recurse
  )
  if (( max_memory > 0 )); then
    eval_args+=(--max-memory-size "$max_memory")
  fi
  eval_args+=("${override_args[@]}" "${nix_args[@]}")

  select_script=$(cat <<'NIXEOF'
tests: let
  system="SYS_PLACEHOLDER";
  go = prefix: v:
    if v ? expr then
      let
        hasExpected = v ? expected && !(v.expected ? undefined);
        hasExpectedError = v ? expectedError && !(v.expectedError ? undefined);
        pass = if hasExpected then v.expr == v.expected
               else if hasExpectedError then true # ignored
               else true;
        name = builtins.replaceStrings ["." "'"] ["-" "_"] prefix;
      in derivation {
        name = if pass then "PASS-${name}" else "FAIL-${name}";
        system = "${system}"; builder = "/bin/sh";
        args = ["-c" "echo > $out"];
      }
    else if builtins.isAttrs v then
      builtins.mapAttrs (k: go (if prefix == "" then k else "${prefix}.${k}")) v
    else derivation { name = "SKIP"; system = "${system}"; builder = "/bin/sh"; args = ["-c" "echo > $out"]; };
in builtins.mapAttrs (k: go k) tests
NIXEOF
)
  select_script="${select_script//SYS_PLACEHOLDER/$system}"

  nix-eval-jobs \
    "${eval_args[@]}" \
    --select "$select_script" \
    2>/dev/null \
    | tee "$results" \
    | jq -r 'if (.name != null and (.name | startswith("PASS-"))) then "✅ '"${postSuite}"'" + .attr else empty end'
fi

# Count results
pass=$(jq -r 'select(.name != null and (.name | startswith("PASS-"))) | "."' "$results" | wc -l)
fail=$(jq -r 'select(.error != null or (.name != null and (.name | startswith("FAIL-")))) | "."' "$results" | wc -l)
total=$(( pass + fail ))

if [ "$fail" -eq "0" ]; then
  (( quiet )) || echo "🎉 ${pass}/${total} successful" >&2
  rm "$results" || true
else
  (( quiet )) || {
    echo >&2
    echo "💥 FAILURES (${fail}):" >&2
    echo "For details run with \`--show-trace\`" >&2
    echo >&2
    jq -r 'select(.error != null or (.name != null and (.name | startswith("FAIL-")))) | "❌ '"${postSuite}"'" + .attr' "$results" >&2
    echo >&2
  }
  echo "😢 ${pass}/${total} successful" >&2
  rm "$results" || true
  exit 1
fi
