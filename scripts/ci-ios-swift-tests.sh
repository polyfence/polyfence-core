#!/usr/bin/env bash
# Resolves Xcode + iOS Simulator for Swift package build/test on GitHub macOS runners.
# Selects Xcode once, then finds the first available simulator destination.
set -euo pipefail

SCHEME="${1:-PolyfenceCore}"

# Select the best available Xcode (one time)
for XCODE in \
  /Applications/Xcode_16.4.app \
  /Applications/Xcode_16.3.app \
  /Applications/Xcode_16.2.app \
  /Applications/Xcode_16.1.app \
  /Applications/Xcode_15.4.app \
  /Applications/Xcode.app; do
  [[ -d "$XCODE" ]] && { export DEVELOPER_DIR="$XCODE"; break; }
done

echo "Using Xcode: ${DEVELOPER_DIR:-default}"
xcodebuild -version

# Query available simulator devices and runtimes
AVAILABLE=$(xcrun simctl list devices available 2>/dev/null || true)

# Find a working destination by checking simulator availability first
for PHONE in "iPhone 16" "iPhone 15" "iPhone SE (3rd generation)"; do
  # Skip phones not installed on this runner
  echo "$AVAILABLE" | grep -q "$PHONE" || continue
  for OS in 18.6 18.5 18.4 18.2 18.1 17.5; do
    DEST="platform=iOS Simulator,name=${PHONE},OS=${OS}"
    echo "Trying: $DEST"

    # Capture output and exit code separately
    set +e
    OUTPUT=$(xcodebuild test -scheme "$SCHEME" -destination "$DEST" 2>&1)
    EXIT_CODE=$?
    set -e
    echo "$OUTPUT"

    if [[ $EXIT_CODE -eq 0 ]]; then
      # xcodebuild succeeded — but check for test failures in output
      if echo "$OUTPUT" | grep -q "TEST EXECUTE SUCCEEDED"; then
        echo "All tests passed."
        exit 0
      elif echo "$OUTPUT" | grep -q "** TEST SUCCEEDED **"; then
        echo "All tests passed."
        exit 0
      elif echo "$OUTPUT" | grep -q "TEST.*FAILED"; then
        echo "::error::Tests failed (xcodebuild exited 0 but tests reported failures)"
        exit 1
      fi
      # No failure markers found — treat as success
      exit 0
    elif [[ $EXIT_CODE -eq 65 ]]; then
      # Exit 65 = build/test failure — no point retrying other destinations
      echo "::error::Build or test failure (exit 65) — not retrying other destinations"
      exit 1
    fi
    echo "Failed with $DEST (exit $EXIT_CODE), trying next..."
  done
done

echo "::error::No working iOS Simulator destination for scheme ${SCHEME}" >&2
xcodebuild -version >&2 || true
xcodebuild -showdestinations -scheme "$SCHEME" >&2 || true
exit 1
