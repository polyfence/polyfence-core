#!/usr/bin/env bash
# Fails when a file is both tracked and matched by .gitignore.
#
# That pairing is how committed build output survives: the file was tracked
# before the ignore rule existed, and once the rule lands git stops reporting
# it in `git status`, so it stays in the repository and in every clone with
# nothing drawing attention to it. Adding the ignore rule alone does not
# untrack what is already tracked.
#
# Generic on purpose. A hardcoded list of output directories would need
# extending for every new toolchain; asking git which tracked files it would
# otherwise ignore covers whatever .gitignore already names.
#
# Negated patterns are respected, so deliberately tracked paths that sit under
# a broader rule (android/gradle.properties, the Gradle wrapper jar) do not
# trip this.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TRACKED_AND_IGNORED=$(git ls-files --cached --ignored --exclude-standard)

if [ -n "$TRACKED_AND_IGNORED" ]; then
  echo "no-tracked-ignored-files: tracked files that .gitignore also ignores:"
  echo "$TRACKED_AND_IGNORED" | sed 's/^/  /'
  echo "Fix: git rm --cached each path, which untracks it and leaves it on disk. If a path has to stay tracked, give it an explicit ! negation in .gitignore so the intent is recorded."
  exit 1
fi

echo "OK: no tracked file is ignored by .gitignore"
