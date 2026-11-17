#!/usr/bin/env bash
#
# Runs every scenario in scenarios.json against Incrementalist and compares the
# detected affected-project set against the hand-written expectation.
#
# Ground truth lives in scenarios.json, NOT in either tool's output. That is the
# whole point: grading one implementation against another only tells you they
# disagree, not which one is right.
#
# Usage:
#   ./run-scenarios.sh              # run all scenarios
#   ./run-scenarios.sh resx-at-project-root   # run one scenario
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

BASE_BRANCH="${BASE_BRANCH:-dev}"
OUT_DIR="$REPO_ROOT/.scenario-output"
FILTER="${1:-}"

mkdir -p "$OUT_DIR"

# Make sure the local tool manifest is restored before anything else.
if ! dotnet tool restore >/dev/null 2>&1; then
  echo "FATAL: dotnet tool restore failed" >&2
  exit 1
fi

# The full project list, used to expand the "FULL" expectation.
mapfile -t ALL_PROJECTS < <(jq -r '.projects[]' scenarios.json)

# Reset to a clean base branch before each scenario so runs are independent.
reset_to_base() {
  git checkout -q "$BASE_BRANCH" 2>/dev/null || {
    echo "FATAL: cannot check out base branch '$BASE_BRANCH'" >&2
    exit 1
  }
  git reset -q --hard "$BASE_BRANCH"
  git clean -qfd -e .scenario-output
}

# Normalize an absolute path list into repo-relative paths, sorted.
normalize() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return
  fi
  sed "s|^$REPO_ROOT/||" "$file" | sed '/^$/d' | sort -u
}

pass=0
fail=0
declare -a failed_names=()

scenario_count=$(jq '.scenarios | length' scenarios.json)

for ((i = 0; i < scenario_count; i++)); do
  name=$(jq -r ".scenarios[$i].name" scenarios.json)

  if [[ -n "$FILTER" && "$name" != "$FILTER" ]]; then
    continue
  fi

  description=$(jq -r ".scenarios[$i].description" scenarios.json)
  change=$(jq -r ".scenarios[$i].change" scenarios.json)
  do_commit=$(jq -r ".scenarios[$i].commit" scenarios.json)
  expected_raw=$(jq -c ".scenarios[$i].expected" scenarios.json)

  echo ""
  echo "=============================================================="
  echo "SCENARIO: $name"
  echo "--------------------------------------------------------------"
  echo "$description"
  echo ""

  reset_to_base
  git checkout -q -B "scenario/$name" "$BASE_BRANCH"

  # Apply the change described by the scenario.
  if ! eval "$change"; then
    echo "  RESULT: ERROR (change command failed)"
    fail=$((fail + 1))
    failed_names+=("$name (change failed)")
    continue
  fi

  if [[ "$do_commit" == "true" ]]; then
    git add -A >/dev/null 2>&1
    git commit -q -m "scenario: $name" >/dev/null 2>&1
  fi

  out_file="$OUT_DIR/$name.txt"
  log_file="$OUT_DIR/$name.log"
  rm -f "$out_file"

  dotnet incrementalist run --dry -b "$BASE_BRANCH" -f "$out_file" >"$log_file" 2>&1
  rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "  RESULT: ERROR (incrementalist exited $rc, see $log_file)"
    fail=$((fail + 1))
    failed_names+=("$name (exit $rc)")
    continue
  fi

  # Build the expected set.
  if [[ "$expected_raw" == '"FULL"' ]]; then
    printf '%s\n' "${ALL_PROJECTS[@]}" | sort -u >"$OUT_DIR/$name.expected"
  else
    jq -r ".scenarios[$i].expected[]" scenarios.json | sort -u >"$OUT_DIR/$name.expected"
  fi

  normalize "$out_file" >"$OUT_DIR/$name.actual"

  if diff -q "$OUT_DIR/$name.expected" "$OUT_DIR/$name.actual" >/dev/null 2>&1; then
    echo "  RESULT: PASS"
    pass=$((pass + 1))
  else
    echo "  RESULT: FAIL"
    echo ""
    echo "  Missing (should have been detected, was not):"
    comm -23 "$OUT_DIR/$name.expected" "$OUT_DIR/$name.actual" | sed 's/^/    - /'
    echo "  Extra (detected but should not have been):"
    comm -13 "$OUT_DIR/$name.expected" "$OUT_DIR/$name.actual" | sed 's/^/    + /'
    fail=$((fail + 1))
    failed_names+=("$name")
  fi
done

reset_to_base

echo ""
echo "=============================================================="
echo "SUMMARY: $pass passed, $fail failed"
if [[ ${#failed_names[@]} -gt 0 ]]; then
  echo ""
  echo "Failing scenarios:"
  printf '  - %s\n' "${failed_names[@]}"
fi
echo "=============================================================="

[[ $fail -eq 0 ]]
