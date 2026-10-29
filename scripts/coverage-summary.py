#!/usr/bin/env python3
"""Line coverage of the app's own code (Sources/), from `swift test --enable-code-coverage`.

Usage: python3 scripts/coverage-summary.py path/to/codecov.json [label]
Prints a Markdown summary (for $GITHUB_STEP_SUMMARY) and a ::notice:: with the total.
"""
import json
import os
import sys

path = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else ""
with open(path, encoding="utf-8") as f:
    data = json.load(f)["data"][0]["files"]

rows, covered, total = [], 0, 0
for entry in data:
    name = entry["filename"]
    if "/Sources/" not in name or "/.build/" in name:
        continue
    lines = entry["summary"]["lines"]
    covered += lines["covered"]
    total += lines["count"]
    rel = name.split("/Sources/", 1)[1]
    rows.append((rel, lines["covered"], lines["count"]))

pct = 100 * covered / total if total else 0.0
bar = "█" * round(pct / 5) + "░" * (20 - round(pct / 5))
print(f"### 🧪 Coverage {label}".rstrip())
print()
print(f"**{pct:.1f}%** of {total:,} lines in `Sources/`  `{bar}`")
print()
print("<details><summary>Per file</summary>\n")
print("| File | Lines | Covered |")
print("|---|---:|---:|")
for rel, c, n in sorted(rows, key=lambda r: (r[1] / r[2]) if r[2] else 1):
    print(f"| `{rel}` | {n} | {100 * c / n if n else 100:.0f}% |")
print("\n</details>")
print(f"::notice title=Coverage::{pct:.1f}% of app lines covered by tests", file=sys.stderr)
