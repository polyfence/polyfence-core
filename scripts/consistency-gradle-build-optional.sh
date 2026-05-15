#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${POLYFENCE_RUN_GRADLE:-}" = 1 ]; then
  cd "$ROOT/android"
  ./gradlew build --quiet
else
  echo "SKIP gradle-build-clean (set POLYFENCE_RUN_GRADLE=1 to run ./gradlew build)"
fi
