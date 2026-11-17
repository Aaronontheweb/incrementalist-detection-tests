# incrementalist-detection-tests

Detection-accuracy fixtures for [Incrementalist](https://github.com/petabridge/Incrementalist)'s affected-project analysis.

## Why this exists

A [blog post comparing affected-detection tools](https://stenbrinke.nl/blog/build-only-what-changed-in-your-dotnet-monorepo/) claims Incrementalist's detection "can produce different results from dotnet-affected, sometimes triggering unnecessary runs or skipping runs that were necessary." No corpus, methodology, or numbers were published, so the claim can't be confirmed or refuted as stated.

This repo is the missing measurement. It is a small, deliberately-shaped .NET solution plus a set of scripted change scenarios, each with a **hand-written expected answer**.

## Ground truth is written by hand, not derived from a tool

The expected affected set for each scenario lives in `scenarios.json`. It is not produced by Incrementalist, and it is not produced by `dotnet-affected`. Grading one implementation against another only tells you they disagree — not which one is right.

## The fixture solution

Seven projects, shaped so each scenario has a distinct answer:

```
Core  <-- Shared <-- App
  ^
  +---- Core.Tests

Other          (imports build/common.props, no dependency on Core)
Unrelated      (imports build/common.props, no dependency on Core)
Unrelated2     (fully isolated)
```

`build/common.props` is explicitly imported by `Core` and `Unrelated` only. `Directory.Build.targets` is auto-imported into everything.

## Running

```bash
dotnet tool restore
./run-scenarios.sh                    # all scenarios
./run-scenarios.sh resx-at-project-root   # one scenario
```

Each scenario resets to `dev`, applies a scripted change, optionally commits it, runs `incrementalist run --dry`, and diffs the result against the expectation. Output lands in `.scenario-output/`.

## Scenarios

| Scenario | Change | Expected |
|---|---|---|
| `resx-at-project-root` | `.resx` in the project directory | Core + dependents |
| `resx-nested-two-levels` | `.resx` in `Resources/en-US/` | Core + dependents |
| `resx-one-level-deep` | `.resx` in `Resources/` (control) | Core + dependents |
| `additional-file` | `appsettings.json` as `AdditionalFiles` | App only |
| `slnx-edited` | `.slnx` touched | full solution |
| `directory-build-targets` | `Directory.Build.targets` touched | full solution || `unstaged-deletion` | source file deleted, not staged | Core + dependents |
| `committed-deletion` | source file deleted and committed | Core + dependents |
| `csproj-property-change` | property added to a leaf `.csproj` | that project only |
| `props-imported-by-two` | `build/common.props` touched | Core, Unrelated + dependents |
| `global-json` | SDK pin changed | full solution |
| `pipeline-yaml-only` | CI workflow touched | nothing |
| `empty-diff` | no changes | nothing |

## Known gaps these scenarios target

Read from Incrementalist 1.2.2 source, then **verified by running the suite**. Two of the source-reading predictions were wrong; the corrections are noted.

### Confirmed failures (6)

1. **Resource files at the project root are missed.** `FilterAffectedProjectFilesCmd.TryFindSubFolder` enumerates *immediate subdirectories* of each project folder. A file directly in the project directory never matches. `resx-at-project-root` returns **zero** affected projects.
2. **Resource files two levels deep are missed.** Same heuristic. `resx-nested-two-levels` (`Resources/en-US/Strings.resx`) also returns **zero**. The one-level-deep control (`Resources/Strings.resx`) passes, which pins the bug precisely to the depth of the folder walk.
3. **`AdditionalDocuments` are never enumerated.** `WorkspaceProject.Documents` only pulls Roslyn `Documents` (source files), so `AdditionalFiles` items are invisible. `additional-file` returns **zero**.
4. **`Directory.Build.targets` is silently dropped.** It is not in the solution's file list, not inside a project subfolder, and not an explicit `<Import>`. `directory-build-targets` returns **zero** affected projects — a false negative on a file that MSBuild auto-imports into every project.
5. **Unstaged deletions are dropped.** `DiffHelper.ChangedFiles` enumerates `status.Modified`, `status.Added`, `status.Untracked` — never `status.Deleted`. `unstaged-deletion` returns **zero**.
6. **Committed deletions are dropped.** Same root cause, and it survives the commit. `committed-deletion` returns **zero**.

### Predictions that were wrong

- **`.slnx` is fine.** I predicted `slnx-edited` would fail because `AlwaysSolutionWideExtensions` only lists `.sln`. It passes: the solution file is in the solution's own file list, so `ComputeDependencyGraphCmd`'s explicit "solution file modified" special case returns all projects. The extension list is still incomplete, but this path doesn't depend on it.
- **`IsWidelyImportedFile` over-triggering is dead code, not a live bug.** I predicted `props-imported-by-two` would force a full solution build. It doesn't: props files never survive into the affected-file set, because `FilterAffectedProjectFilesCmd` replaces them with the projects that import them. The over-trigger branch is unreachable for the case it was written for.

### Still unverified

- **`ProjectImportsFinder` only reads `//Import` nodes.** Misses `ImportGroup`, `Sdk` attribute imports, and the implicit `Directory.Build.props` auto-import. No scenario covers this yet.

## Current status against Incrementalist 1.2.2

```
7 passed, 6 failed
```

Failing: `resx-at-project-root`, `resx-nested-two-levels`, `additional-file`, `directory-build-targets`, `unstaged-deletion`, `committed-deletion`.

Every failure is a **false negative** — Incrementalist reports zero affected projects when work is genuinely needed. That is the dangerous direction: a skipped build ships stale code. None of the six are false positives.


## License

Apache-2.0
