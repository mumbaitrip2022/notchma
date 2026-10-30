#!/bin/bash
# The fast checks CI runs first. The pre-commit hook runs them too, so a commit that
# would fail CI's Lint or Website check never leaves your Mac. Takes well under a second.
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/check-copy.sh

if git grep -nE '^(<{7}|={7}|>{7})( |$)' -- ':!*.md'; then
  echo "Found leftover merge conflict markers."
  exit 1
fi
echo "No conflict markers."

python3 scripts/check-site.py docs
