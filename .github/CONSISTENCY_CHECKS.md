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

## Phase 3

Version drift between CocoaPods and Gradle stays in `podspec-gradle-version-match`. README/privacy anchors add brand + template headline coverage without touching gitignored per-machine bootstrap files in public SDK clones.
