#!/usr/bin/env python3
"""Turns `swift test --xunit-output` results into a Markdown summary for the CI run page."""
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

path, title = sys.argv[1], sys.argv[2]
root = ET.parse(path).getroot()
cases = root.iter("testcase")

suites = defaultdict(lambda: {"tests": 0, "failed": 0, "time": 0.0})
failures = []
for c in cases:
    suite = c.get("classname", "?").split(".")[-1]
    s = suites[suite]
    s["tests"] += 1
    s["time"] += float(c.get("time", 0) or 0)
    f = c.find("failure")
    if f is None:
        f = c.find("error")
    if f is not None:
        s["failed"] += 1
        failures.append(f"{suite}.{c.get('name')}: {(f.get('message') or '').strip()[:200]}")

total = sum(s["tests"] for s in suites.values())
failed = sum(s["failed"] for s in suites.values())
secs = sum(s["time"] for s in suites.values())
icon = "✅" if failed == 0 else "❌"

print(f"### {icon} {title}: {total - failed}/{total} tests passed in {secs:.1f}s\n")
print("| Suite | Tests | Failed | Time |")
print("|---|---:|---:|---:|")
for name, s in sorted(suites.items(), key=lambda kv: -kv[1]["time"]):
    print(f"| {name} | {s['tests']} | {s['failed'] or ''} | {s['time']:.2f}s |")
if failures:
    print("\n**Failures**\n")
    for f in failures:
        print(f"- `{f}`")
sys.exit(1 if failed else 0)
