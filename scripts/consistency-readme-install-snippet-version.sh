#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Source of truth for the library version.
gradle="$(grep -E '^\s*version\s*=' android/build.gradle.kts | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [ -z "$gradle" ]; then
  echo "could not extract version from android/build.gradle.kts"
  exit 1
fi

fail=0

# CocoaPods snippet in README:  pod 'PolyfenceCore', '~> X.Y.Z'
pod_version="$(grep -E "^\s*pod\s+['\"]PolyfenceCore['\"]" README.md | head -1 | sed -E "s/.*['\"]~>[[:space:]]*([0-9.]+)['\"].*/\1/" || true)"
if [ -z "$pod_version" ]; then
  echo "README.md: could not find 'pod \"PolyfenceCore\", \"~> X.Y.Z\"' install snippet"
  fail=1
elif [ "$pod_version" != "$gradle" ]; then
  echo "README.md CocoaPods snippet: ~> $pod_version does not match current library version $gradle"
  fail=1
fi

# Swift Package Manager snippet:  .package(url: "...polyfence-core...", from: "X.Y.Z")
spm_version="$(grep -E "\.package\(url:.*polyfence-core" README.md | head -1 | sed -E 's/.*from:[[:space:]]*"([0-9.]+)".*/\1/' || true)"
if [ -z "$spm_version" ]; then
  echo "README.md: could not find Swift Package Manager '.package(url:..., from:\"X.Y.Z\")' snippet"
  fail=1
elif [ "$spm_version" != "$gradle" ]; then
  echo "README.md SPM snippet: from: \"$spm_version\" does not match current library version $gradle"
  fail=1
fi

# Maven / Gradle snippet:  implementation("io.polyfence:polyfence-core:X.Y.Z")
maven_version="$(grep -E 'implementation\("io\.polyfence:polyfence-core' README.md | head -1 | sed -E 's/.*polyfence-core:([0-9.]+).*/\1/' || true)"
if [ -z "$maven_version" ]; then
  echo "README.md: could not find Maven 'implementation(\"io.polyfence:polyfence-core:X.Y.Z\")' snippet"
  fail=1
elif [ "$maven_version" != "$gradle" ]; then
  echo "README.md Maven snippet: :$maven_version does not match current library version $gradle"
  fail=1
fi

exit $fail
