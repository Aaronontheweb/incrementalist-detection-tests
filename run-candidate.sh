#!/usr/bin/env bash
#
# Runs the scenario suite against a CANDIDATE Incrementalist build instead of the
# pinned 1.2.2 from the tool manifest. Used to validate fixes before release.
#
# Usage:
#   CANDIDATE=/path/to/incrementalist ./run-candidate.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

BASE_BRANCH="${BASE_BRANCH:-dev}"
OUT_DIR="$REPO_ROOT/.scenario-output-candidate"
CANDIDATE="${CANDIDATE:-/tmp/netclaw-1000/b9ebe1171521bed2/p/candidate/incrementalist}"

if [[ ! -x "$CANDIDATE" ]]; then
  echo "FATAL: candidate executable not found at $CANDIDATE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
mapfile -t ALL_PROJECTS < <(jq -r '.projects[]' scenarios.json)

reset_to_base() {
  git checkout -q "$BASE_BRANCH" 2>/dev/null || { echo "FATAL: bad base branch" >&2; exit 1; }
  git reset -q --hard "$BASE_BRANCH"
  git clean -qfd -e .scenario-output -e .scenario-output-candidate
}

normalize() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed "s|^$REPO_ROOT/||" "$file" | sed '/^$/d' | sort -u
}

pass=0; fail=0
declare -a failed_names=()
scenario_count=$(jq '.scenarios | length' scenarios.json)

for ((i = 0; i < scenario_count; i++)); do
  name=$(jq -r ".scenarios[$i].name" scenarios.json)
  change=$(jq -r ".scenarios[$i].change" scenarios.json)
  do_commit=$(jq -r ".scenarios[$i].commit" scenarios.json)
  expected_raw=$(jq -c ".scenarios[$i].expected" scenarios.json)

  reset_to_base
  git checkout -q -B "cand/$name" "$BASE_BRANCH"

  if ! eval "$change"; then
    echo "$name: ERROR (change failed)"; fail=$((fail+1)); failed_names+=("$name"); continue
  fi

  if [[ "$do_commit" == "true" ]]; then
    git add -A >/dev/null 2>&1
    git commit -q -m "scenario: $name" >/dev/null 2>&1
  fi

  if [[ "$expected_raw" == '"FULL"' ]]; then
    printf '%s\n' "${ALL_PROJECTS[@]}" | sort -u >"$OUT_DIR/$name.expected"
  else
    jq -r ".scenarios[$i].expected[]" scenarios.json | sort -u >"$OUT_DIR/$name.expected"
  fi

  raw="$OUT_DIR/$name.raw"
  rm -f "$raw"
  DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}" "$CANDIDATE" run --dry -b "$BASE_BRANCH" -f "$raw" >"$OUT_DIR/$name.log" 2>&1
  rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "$name: ERROR (exit $rc)"; fail=$((fail+1)); failed_names+=("$name"); continue
  fi

  normalize "$raw" >"$OUT_DIR/$name.actual"

  if diff -q "$OUT_DIR/$name.expected" "$OUT_DIR/$name.actual" >/dev/null 2>&1; then
    printf '%-32s PASS\n' "$name"; pass=$((pass+1))
  else
    printf '%-32s FAIL\n' "$name"; fail=$((fail+1)); failed_names+=("$name")
    comm -23 "$OUT_DIR/$name.expected" "$OUT_DIR/$name.actual" | sed 's/^/    missing: /'
    comm -13 "$OUT_DIR/$name.expected" "$OUT_DIR/$name.actual" | sed 's/^/    extra:   /'
  fi
done

reset_to_base

echo ""
echo "=============================================="
echo "CANDIDATE: $pass passed, $fail failed"
[[ ${#failed_names[@]} -gt 0 ]] && printf '  - %s\n' "${failed_names[@]}"
echo "=============================================="
[[ $fail -eq 0 ]]
