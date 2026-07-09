#!/usr/bin/env bash
# Sync polyfence-core library version across all files.
#
# Source of truth: android/build.gradle.kts (the `version = "X.Y.Z"` line).
# Usage: edit build.gradle.kts to the new version FIRST, then run this script.
# The companion `scripts/consistency-check.sh --local-only` verifies nothing
# drifted afterwards; pre-push runs it automatically.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(grep -E '^\s*version\s*=' android/build.gradle.kts | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [ -z "$VERSION" ]; then
    echo "Error: could not extract version from android/build.gradle.kts"
    exit 1
fi

echo "Syncing polyfence-core to version $VERSION..."

# CocoaPods podspec — `s.version = 'X.Y.Z'`
sed -i '' "s/^\([[:space:]]*s\.version[[:space:]]*=[[:space:]]*\)['\"][^'\"]*['\"]/\1'$VERSION'/" PolyfenceCore.podspec

# Kotlin version constant
sed -i '' "s/const val VERSION = \"[^\"]*\"/const val VERSION = \"$VERSION\"/" \
    android/src/main/kotlin/io/polyfence/core/PolyfenceCoreVersion.kt

# Swift version constant
sed -i '' "s/public static let version = \"[^\"]*\"/public static let version = \"$VERSION\"/" \
    ios/Classes/PolyfenceCoreVersion.swift

# README install snippets — CocoaPods, SwiftPM, Maven
sed -i '' "s|pod 'PolyfenceCore', '~> [0-9][0-9.]*'|pod 'PolyfenceCore', '~> $VERSION'|" README.md
sed -i '' "s|\(polyfence-core\.git\", from: \)\"[0-9][0-9.]*\"|\1\"$VERSION\"|" README.md
sed -i '' "s|implementation(\"io\\.polyfence:polyfence-core:[0-9][0-9.]*\")|implementation(\"io.polyfence:polyfence-core:$VERSION\")|" README.md

echo "Synced to $VERSION:"
echo "  android/build.gradle.kts  (source of truth)"
echo "  PolyfenceCore.podspec"
echo "  android/src/main/kotlin/io/polyfence/core/PolyfenceCoreVersion.kt"
echo "  ios/Classes/PolyfenceCoreVersion.swift"
echo "  README.md install snippets x 3 (pod / SwiftPM / Maven)"
echo
echo "Verify with: bash scripts/consistency-check.sh --local-only"
