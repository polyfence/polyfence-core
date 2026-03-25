#!/usr/bin/env bash
# Resolves Xcode + iOS Simulator for Swift package build/test on GitHub macOS runners.
# Default Xcode on macos-14 is 15.x (no iPhone 16); macos-15 defaults to 16.x. Try pairs in order.
set -euo pipefail

SCHEME="${1:-PolyfenceCore}"

for XCODE in \
  /Applications/Xcode_16.4.app \
  /Applications/Xcode_16.3.app \
  /Applications/Xcode_16.2.app \
  /Applications/Xcode_16.1.app \
  /Applications/Xcode_15.4.app \
  /Applications/Xcode.app; do
  [[ -d "$XCODE" ]] || continue
  export DEVELOPER_DIR="$XCODE"
  for PHONE in "iPhone 16" "iPhone 15"; do
    for OS in 18.5 18.4 18.2 18.1 17.5; do
      DEST="platform=iOS Simulator,name=${PHONE},OS=${OS}"
      # test implies build — running both doubles compile time on CI.
      if xcodebuild test -scheme "$SCHEME" -destination "$DEST"; then
        exit 0
      fi
    done
  done
done

echo "::error::No working iOS Simulator destination for scheme ${SCHEME}" >&2
xcodebuild -version >&2 || true
xcodebuild -showdestinations -scheme "$SCHEME" >&2 || true
exit 1
