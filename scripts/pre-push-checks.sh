#!/bin/bash
# Pre-push quality checks — runs locally before push to save CI minutes
# Install: cp scripts/pre-push-checks.sh .git/hooks/pre-push && chmod +x .git/hooks/pre-push
set -e

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

echo "Running pre-push checks..."

# Code quality checks (moved from CI)
echo "  Checking for emojis in production code..."
if grep -rPn '[\x{1F600}-\x{1F64F}\x{1F300}-\x{1F5FF}\x{1F680}-\x{1F6FF}\x{1F1E0}-\x{1F1FF}\x{2702}-\x{27B0}\x{FE00}-\x{FE0F}\x{1F900}-\x{1F9FF}]' android/src/ ios/Classes/ 2>/dev/null; then
  echo "ERROR: Emojis found in production code"
  exit 1
fi

echo "  Checking for internal files in git..."
for file in CLAUDE.md .cursorrules; do
  if [ -f "$file" ] && git ls-files --error-unmatch "$file" 2>/dev/null; then
    echo "ERROR: Internal file $file is tracked in git"
    exit 1
  fi
done
for dir in tasks/ prompts/ .claude/; do
  if git ls-files | grep -q "^${dir}"; then
    echo "ERROR: ${dir} directory is tracked in git"
    exit 1
  fi
done

echo "  Checking for secrets..."
if grep -rPn '(sk_live_|sk_test_|pk_live_|pk_test_|AKIA[A-Z0-9]{16}|ghp_[a-zA-Z0-9]{36}|xoxb-|xoxp-)' --include="*.kt" --include="*.swift" --include="*.java" --include="*.xml" --include="*.yaml" --include="*.yml" --include="*.json" --include="*.properties" . 2>/dev/null | grep -v '.gradle/' | grep -v 'node_modules'; then
  echo "ERROR: Potential secrets found in code"
  exit 1
fi

echo "  Checking for internal references..."
if grep -rn 'Teslon\|Sector7' --include="*.kt" --include="*.swift" android/src/ ios/Classes/ 2>/dev/null; then
  echo "ERROR: Internal references found in production code"
  exit 1
fi

# Android build + test
echo "  Building Android..."
cd android && ./gradlew build --quiet && ./gradlew test --quiet
cd "$REPO_ROOT"

echo "All pre-push checks passed."
