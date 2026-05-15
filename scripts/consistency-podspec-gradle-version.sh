#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pod="$(grep -E "^\s*s\.version\s*=" PolyfenceCore.podspec | head -1 | sed -E "s/.*['\"]([0-9.]+)['\"].*/\1/")"
gradle="$(grep -E '^\s*version\s*=' android/build.gradle.kts | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [ -z "$pod" ] || [ -z "$gradle" ]; then
  echo "could not extract version from Podspec or build.gradle.kts"
  exit 1
fi
if [ "$pod" != "$gradle" ]; then
  echo "Podspec version ${pod} != android/build.gradle.kts version ${gradle}"
  exit 1
fi
