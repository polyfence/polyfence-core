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
# The PolyfenceCoreVersion constants are stamped into telemetry as core_version —
# keep them in sync with the release version or core_version drifts silently.
grep -qF "VERSION = \"$pod\"" android/src/main/kotlin/io/polyfence/core/PolyfenceCoreVersion.kt || {
  echo "PolyfenceCoreVersion.kt VERSION out of sync with ${pod} (stamped into core_version telemetry)"
  exit 1
}
grep -qF "version = \"$pod\"" ios/Classes/PolyfenceCoreVersion.swift || {
  echo "PolyfenceCoreVersion.swift version out of sync with ${pod} (stamped into core_version telemetry)"
  exit 1
}
