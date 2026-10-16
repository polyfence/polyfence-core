# Consistency Checks

## Requires

Ruby ≥ 2.6 for the runner. macOS ships this by default. The `scripts/consistency-check.sh` bash dispatcher exits with a clear message if `ruby` is not on `PATH`. Other polyfence SDK repos use different runtime ports of the same YAML schema.

## Overview

Declarative registry: `consistency-checks.yaml` at repo root. Runner entrypoint: `scripts/consistency-check.sh` (invokes `scripts/consistency_check_runner.rb`). Runs locally before push via `scripts/pre-push-checks.sh`.

## Commands

```bash
bash scripts/consistency-check.sh --local-only
```

Optional Gradle drift confirmation:

```bash
POLYFENCE_RUN_GRADLE=1 bash scripts/consistency-check.sh --local-only
```

## Seed checks

| id | intent |
| --- | --- |
| bootstrap-files-not-tracked | Keep agent scaffold paths untracked |
| podspec-gradle-version-match | Single semver across CocoaPods + Android artefacts |
| readme-cites-brand-positioning | README echoes canonical positioning language |
| privacy-md-zero-pii-headline | `PRIVACY.md` retains the template zero-PII headline |
| readme-canonical-define-once-phrase | README still carries the define-once / cross-surface pitch fragment |
| gradle-build-clean | Heavy `./gradlew build` only when opted-in |

## Results

Each check prints `PASS <id>`, `SKIP <id> (<reason>)`, or `FAIL <id>` with the `fix:` text from the YAML, then a summary line counting each. A skip means the check did not run, so it never counts as a pass. Skips do not fail the run (a missing optional tool must not block a push), but the summary names every skipped check as not verified and says `all passed` only when nothing was skipped.

A `subprocess` script reports a skip by printing `SKIP_REASON: <why>` as its last line of stdout and exiting 77. Both are required: exit 77 without that last line is reported as FAIL, so a script that happens to die with 77 cannot pass itself off as a skip. Exit 0 always means PASS, so a script that exits 0 is reported as FAIL if any line of its stdout or stderr matches `^\s*SKIP\b` or `^\s*SKIP_REASON:` (at any indentation, so `SKIP x`, `  SKIP x` and `SKIP: x` all count).

The run exits 0 when nothing failed, 1 when a check failed, and 2 when the run itself is wrong: no `consistency-checks.yaml`, a `--check` id that matches no entry (`FAIL: no check with id <id>`), or a selection that verified nothing: no check ran at all (`RESULT: no checks ran`, for example `--remote-only` in this repo, which has no `remote-query` checks), or every selected check was skipped (`RESULT: nothing verified`, for example `--check` on a single optional check whose tool is missing).

## Phase 3

Version drift between CocoaPods and Gradle stays in `podspec-gradle-version-match`. README/privacy anchors add brand + template headline coverage without touching gitignored per-machine bootstrap files in public SDK clones.
