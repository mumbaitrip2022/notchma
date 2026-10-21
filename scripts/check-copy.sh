#!/bin/bash
# House style: no em or en dashes in text people read in the app.
# (They read as machine written. Use a period, a comma or "and" instead.)
set -euo pipefail
cd "$(dirname "$0")/.."
hits=$(grep -rnE '"[^"]*[—–][^"]*"' Sources | grep -vE '^[^:]+:[0-9]+:\s*//' || true)
if [[ -n "$hits" ]]; then
  echo "Found em or en dashes in app strings:"
  echo "$hits"
  exit 1
fi
echo "App text is clean."
