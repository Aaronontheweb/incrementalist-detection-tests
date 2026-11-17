#!/usr/bin/env bash
#
# Runs every scenario in scenarios.json against BOTH Incrementalist and
# dotnet-affected, and compares each tool's detected affected-project set
# against the hand-written expectation.
#
# Ground truth lives in scenarios.json, NOT in either tool's output. That is the
# whole point: grading one implementation against another only tells you they
# disagree, not which one is right.
#
# Usage:
#   ./run-scenarios.sh                       # run all scenarios, both tools
#   ./run-scenarios.sh resx-at-project-root  # run one scenario
#   TOOLS=incrementalist ./run-scenarios.sh  # run only one tool
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

BASE_BRANCH="${BASE_BRANCH:-dev}"
OUT_DIR="$REPO_ROOT/.scenario-output"
FILTER="${1:-}"
TOOLS="${TOOLS:-incrementalist dotnet-affected}"

mkdir -p "$OUT_DIR"

if ! dotnet tool restore >/dev/null 2>&1; then
  echo "FATAL: dotnet tool restore failed" >&2
  exit 1
fi

mapfile -t ALL_PROJECTS < <(jq -r '.projects[]' scenarios.json)

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
  [[ -f "$file" ]] || return 0
  sed "s|^$REPO_ROOT/||" "$file" | sed '/^$/d' | sort -u
}

# Run one tool, write normalized output to $2. Returns 0 on success.
run_tool() {
  local tool="$1" out="$2" log="$3"
  rm -f "$out"

  case "$tool" in
    incrementalist)
      dotnet incrementalist run --dry -b "$BASE_BRANCH" -f "$out.raw" >"$log" 2>&1
      local rc=$?
      [[ $rc -ne 0 ]] && return $rc
      normalize "$out.raw" >"$out"
      ;;
    dotnet-affected)
      local da_dir="$OUT_DIR/.da"
      rm -rf "$da_dir"; mkdir -p "$da_dir"
      # --uncommitted all matches Incrementalist's behavior: DiffHelper.ChangedFiles
      # includes staged, unstaged and untracked changes on top of the branch diff.
      # Using `none` here would unfairly hide working-tree changes from dotnet-affected.
      dotnet dotnet-affected --from "$BASE_BRANCH" --uncommitted all \
        --format text --output-dir "$da_dir" --output-name affected >"$log" 2>&1
      local rc=$?
      # 166 means "nothing is affected" -- a valid empty result, not an error.
      if [[ $rc -eq 166 ]]; then
        : >"$out"
        return 0
      fi
      [[ $rc -ne 0 ]] && return $rc
      normalize "$da_dir/affected.txt" >"$out"
      ;;
  esac
  return 0
}

declare -A results
declare -a scenario_names=()

scenario_count=$(jq '.scenarios | length' scenarios.json)

for ((i = 0; i < scenario_count; i++)); do
  name=$(jq -r ".scenarios[$i].name" scenarios.json)
  [[ -n "$FILTER" && "$name" != "$FILTER" ]] && continue

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

  if ! eval "$change"; then
    echo "  ERROR: change command failed"
    for tool in $TOOLS; do results["$name|$tool"]="ERROR"; done
    scenario_names+=("$name")
    continue
  fi

  if [[ "$do_commit" == "true" ]]; then
    git add -A >/dev/null 2>&1
    git commit -q -m "scenario: $name" >/dev/null 2>&1
  fi

  # Build the expected set once per scenario.
  if [[ "$expected_raw" == '"FULL"' ]]; then
    printf '%s\n' "${ALL_PROJECTS[@]}" | sort -u >"$OUT_DIR/$name.expected"
  else
    jq -r ".scenarios[$i].expected[]" scenarios.json | sort -u >"$OUT_DIR/$name.expected"
  fi

  for tool in $TOOLS; do
    actual="$OUT_DIR/$name.$tool.actual"
    log="$OUT_DIR/$name.$tool.log"

    if run_tool "$tool" "$actual" "$log"; then
      if diff -q "$OUT_DIR/$name.expected" "$actual" >/dev/null 2>&1; then
        verdict="PASS"
      else
        verdict="FAIL"
      fi
    else
      verdict="ERROR"
    fi
    results["$name|$tool"]="$verdict"

    printf '  %-18s %s\n' "$tool" "$verdict"
    if [[ "$verdict" == "FAIL" ]]; then
      comm -23 "$OUT_DIR/$name.expected" "$actual" 2>/dev/null | sed 's/^/      missing: /'
      comm -13 "$OUT_DIR/$name.expected" "$actual" 2>/dev/null | sed 's/^/      extra:   /'
    fi
  done

  scenario_names+=("$name")
done

reset_to_base

# ---------------------------------------------------------------- summary table
echo ""
echo "=============================================================="
echo "COMPARISON"
echo "=============================================================="
printf '%-32s' "SCENARIO"
for tool in $TOOLS; do printf '%-18s' "$tool"; done
echo ""
printf '%-32s' "--------------------------------"
for tool in $TOOLS; do printf '%-18s' "------------------"; done
echo ""

declare -A totals
for tool in $TOOLS; do totals["$tool|pass"]=0; totals["$tool|fail"]=0; done

for name in "${scenario_names[@]}"; do
  printf '%-32s' "$name"
  for tool in $TOOLS; do
    v="${results["$name|$tool"]:-SKIP}"
    printf '%-18s' "$v"
    [[ "$v" == "PASS" ]] && totals["$tool|pass"]=$((totals["$tool|pass"] + 1))
    [[ "$v" == "FAIL" || "$v" == "ERROR" ]] && totals["$tool|fail"]=$((totals["$tool|fail"] + 1))
  done
  echo ""
done

echo ""
printf '%-32s' "TOTALS"
for tool in $TOOLS; do
  printf '%-18s' "${totals["$tool|pass"]} pass / ${totals["$tool|fail"]} fail"
done
echo ""
echo "=============================================================="

for tool in $TOOLS; do
  [[ ${totals["$tool|fail"]} -gt 0 ]] && exit 1
done
exit 0
