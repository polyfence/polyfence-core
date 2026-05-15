# Consistency Checks

## Requires

Ruby ≥ 2.6 for the runner. macOS ships this by default. The `scripts/consistency-check.sh` bash dispatcher exits with a clear message if `ruby` is not on `PATH`. (The org's other consistency-check installs use TypeScript or Python; the YAML schema is identical across all runtime ports.)

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
| gradle-build-clean | Heavy `./gradlew build` only when opted-in |

Add checks by editing YAML — subprocess delegates to scripts under `scripts/`.
