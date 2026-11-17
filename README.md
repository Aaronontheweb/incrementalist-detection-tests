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
| `directory-build-targets` | `Directory.Build.targets` touched | full solution |
| `unstaged-deletion` | source file deleted, not staged | Core + dependents |
| `committed-deletion` | source file deleted and committed | Core + dependents |
| `csproj-property-change` | property added to a leaf `.csproj` | that project only |
| `props-imported-by-two` | `build/common.props` touched | Core, Unrelated + dependents |
| `global-json` | SDK pin changed | full solution |
| `pipeline-yaml-only` | CI workflow touched | nothing |
| `empty-diff` | no changes | nothing |

## Known gaps these scenarios target

Read from Incrementalist 1.2.2 source:

1. **`.slnx` is not solution-wide.** `SolutionWideChangeDetector.AlwaysSolutionWideExtensions` contains only `.sln`, despite `.slnx` support landing in 1.2.0.
2. **`Directory.Build.targets` is not solution-wide.** The list is `Directory.Build.props`, `Directory.Packages.props`, `global.json`, `nuget.config`.
3. **`AdditionalDocuments` are never enumerated.** `WorkspaceProject.Documents` only pulls Roslyn `Documents` (source files), so `AdditionalFiles` items are invisible.
4. **Resource files at the project root are missed.** `FilterAffectedProjectFilesCmd.TryFindSubFolder` enumerates *immediate subdirectories* of each project folder. A file directly in the project directory never matches, and neither does anything two levels deep.
5. **Unstaged deletions are dropped.** `DiffHelper.ChangedFiles` enumerates `status.Modified`, `status.Added`, `status.Untracked` — never `status.Deleted`.
6. **`IsWidelyImportedFile` over-triggers.** A props file imported by 2 of 50 projects forces a *full solution* build instead of just those 2 plus dependents.
7. **`ProjectImportsFinder` only reads `//Import` nodes.** Misses `ImportGroup`, `Sdk` attribute imports, and the implicit `Directory.Build.props` auto-import.

Scenarios 1–6 should fail against 1.2.2. That is the point: this is a failing test suite that documents the gaps, and each fix turns one red.

## License

Apache-2.0
