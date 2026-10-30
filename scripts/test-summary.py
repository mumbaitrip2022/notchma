#!/usr/bin/env python3
"""Turns `swift test --xunit-output` results into the test report on the CI run page.

Writes Markdown to $GITHUB_STEP_SUMMARY (or stdout when run by hand) and prints an error
annotation per failing test, so failures show up at the top of the run and on the PR."""
import os
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

path, title = sys.argv[1], sys.argv[2]
root = ET.parse(path).getroot()

suites = defaultdict(list)   # suite -> [(test, seconds, failure message or None)]
for c in root.iter("testcase"):
    suite = c.get("classname", "?").split(".")[-1]
    f = c.find("failure")
    if f is None:
        f = c.find("error")
    msg = None if f is None else ((f.get("message") or f.text or "failed").strip())
    suites[suite].append((c.get("name", "?"), float(c.get("time", 0) or 0), msg))

tests = [(s, n, t, m) for s, cs in suites.items() for n, t, m in cs]
total, failed = len(tests), sum(1 for *_, m in tests if m)
secs = sum(t for _, _, t, _ in tests)

def bar(done, of, width=10):
    filled = round(width * done / of) if of else 0
    if done < of:
        filled = min(filled, width - 1)   # any failure shows at least one red square
    return "🟩" * filled + "🟥" * (width - filled)

out = []
icon = "✅" if failed == 0 else "❌"
out.append(f"### {icon} {title}: {total - failed}/{total} tests passed in {secs:.1f}s\n")
out.append(f"{bar(total - failed, total)}\n")
out.append("| Suite | Tests | Failed | Time |")
out.append("|---|---:|---:|---:|")
for name, cs in sorted(suites.items(), key=lambda kv: -sum(t for _, t, _ in kv[1])):
    bad = sum(1 for *_, m in cs if m)
    out.append(f"| {'❌' if bad else '✅'} {name} | {len(cs)} | {bad or ''} | {sum(t for _, t, _ in cs):.2f}s |")

if failed:
    out.append("\n**Failures**\n")
    for s, n, _, m in tests:
        if m:
            out.append(f"- **{s}.{n}**: `{m.splitlines()[0][:200]}`")
            # Shows on the run page and on the PR, without opening the log.
            print(f"::error title=Test failed on {title}::{s}.{n}: {m.splitlines()[0][:300]}")

slow = sorted(tests, key=lambda x: -x[2])[:5]
out.append("\n<details><summary>🐢 Slowest tests</summary>\n")
out.append("| Test | Time |\n|---|---:|")
out += [f"| {s}.{n} | {t:.2f}s |" for s, n, t, _ in slow]
out.append("\n</details>\n")

out.append(f"<details><summary>📋 All {total} tests</summary>\n")
for name in sorted(suites):
    out.append(f"\n**{name}**\n")
    out += [f"- {'❌' if m else '✅'} {n} <sub>{t:.2f}s</sub>" for n, t, m in sorted(suites[name])]
out.append("\n</details>\n")

text = "\n".join(out) + "\n"
dest = os.environ.get("GITHUB_STEP_SUMMARY")
if dest:
    with open(dest, "a") as f:
        f.write(text)
else:
    sys.stdout.write(text)
# The test step itself already fails the job; this only reports.
