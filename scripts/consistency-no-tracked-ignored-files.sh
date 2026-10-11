#!/usr/bin/env bash
# Fails when a file is both tracked and ignored by a committed .gitignore rule.
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
# Only committed rules count. `--exclude-standard` also consults a
# contributor's global core.excludesFile and this clone's .git/info/exclude,
# both of which are personal: someone who globally ignores *.log or *.md would
# otherwise see this fail on files the repository itself does not ignore. The
# global file is switched off below, and .git/info/exclude is filtered out by
# keeping only candidates whose matching rule comes from a .gitignore.
#
# Negated patterns are respected, so deliberately tracked paths that sit under
# a broader rule (android/gradle.properties, the Gradle wrapper jar) do not
# trip this.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GIT_NO_GLOBAL_EXCLUDES=(git -c core.excludesFile=/dev/null)

CANDIDATES=$("${GIT_NO_GLOBAL_EXCLUDES[@]}" ls-files --cached --ignored --exclude-standard)

OFFENDERS=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  # check-ignore -v prints "<source>:<line>:<pattern>\t<path>". Keep the file
  # only when the rule that matched lives in a .gitignore, which excludes
  # .git/info/exclude.
  #
  # --no-index is required: without it check-ignore reports nothing for a
  # tracked path, since tracking wins over an ignore rule, and every path
  # reaching this loop is tracked by definition.
  SOURCE=$("${GIT_NO_GLOBAL_EXCLUDES[@]}" check-ignore --no-index -v -- "$path" 2>/dev/null | head -1 | cut -d: -f1 || true)
  case "$SOURCE" in
    *.gitignore) OFFENDERS="${OFFENDERS}${path}"$'\n' ;;
  esac
done <<EOF
$CANDIDATES
EOF

if [ -n "${OFFENDERS//[$'\n']/}" ]; then
  echo "no-tracked-ignored-files: tracked files that a committed .gitignore rule also ignores:"
  printf '%s' "$OFFENDERS" | sed '/^$/d; s/^/  /'
  echo "Fix: git rm --cached each path, which untracks it and leaves it on disk here. Note that pulling the change deletes it from other working trees. If a path has to stay tracked, give it an explicit ! negation in .gitignore so the intent is recorded."
  exit 1
fi

echo "OK: no tracked file is ignored by a committed .gitignore rule"
