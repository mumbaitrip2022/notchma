#!/usr/bin/env python3
"""Checks the website in docs/: every local link, image and #anchor resolves,
pages stay under a size budget, and scripts only load from trusted CDNs.

Usage: python3 scripts/check-site.py [docs]
Writes a table to $GITHUB_STEP_SUMMARY when it runs in GitHub Actions.
"""
import os
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote

ROOT = sys.argv[1] if len(sys.argv) > 1 else "docs"
PAGE_BUDGET_KB = 200          # one HTML page, inline CSS and JS included
IMAGE_BUDGET_KB = 600         # any single image
SCRIPT_HOSTS = {"cdnjs.cloudflare.com", "cdn.jsdelivr.net", "unpkg.com"}


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids, self.links, self.scripts = set(), [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        for key in ("id", "name"):
            if a.get(key) and (key == "id" or tag == "a"):
                self.ids.add(a[key])
        for key in ("href", "src"):
            if a.get(key):
                self.links.append((tag, key, a[key], self.getpos()[0]))
        if tag == "script" and a.get("src"):
            self.scripts.append((a["src"], self.getpos()[0]))


def parse(path):
    p = Page()
    with open(path, encoding="utf-8") as f:
        p.feed(f.read())
    return p


def main():
    pages = sorted(os.path.join(d, f) for d, _, fs in os.walk(ROOT) for f in fs if f.endswith(".html"))
    if not pages:
        print(f"No pages under {ROOT}")
        return 1
    parsed = {p: parse(p) for p in pages}
    problems, rows, checked = [], [], 0

    for page, doc in parsed.items():
        size_kb = os.path.getsize(page) / 1024
        if size_kb > PAGE_BUDGET_KB:
            problems.append(f"{page}: {size_kb:.0f} KB, over the {PAGE_BUDGET_KB} KB page budget")
        for src, line in doc.scripts:
            host = urlsplit(src).hostname
            if host and host not in SCRIPT_HOSTS:
                problems.append(f"{page}:{line}: script from untrusted host {host}")
        for tag, key, url, line in doc.links:
            u = urlsplit(url)
            if u.scheme or url.startswith(("//", "data:", "mailto:", "javascript:")) or "${" in url:
                continue                        # external, inline or built at runtime
            checked += 1
            target = page
            if u.path:
                target = os.path.normpath(os.path.join(os.path.dirname(page), unquote(u.path)))
                if os.path.isdir(target):
                    target = os.path.join(target, "index.html")
                if not os.path.exists(target):
                    problems.append(f"{page}:{line}: <{tag} {key}> points to missing {url}")
                    continue
                if target.endswith((".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg")):
                    kb = os.path.getsize(target) / 1024
                    if kb > IMAGE_BUDGET_KB:
                        problems.append(f"{target}: {kb:.0f} KB, over the {IMAGE_BUDGET_KB} KB image budget")
            if u.fragment and target.endswith(".html"):
                ids = parsed[target].ids if target in parsed else parse(target).ids
                if u.fragment not in ids:
                    problems.append(f"{page}:{line}: #{u.fragment} not found in {os.path.relpath(target, ROOT)}")
        rows.append((os.path.relpath(page, ROOT), f"{size_kb:.0f} KB", len(doc.links)))

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(f"### {'✅' if not problems else '❌'} Website\n\n| Page | Size | Links |\n|---|---:|---:|\n")
            for r in rows:
                f.write(f"| `{r[0]}` | {r[1]} | {r[2]} |\n")
            f.write(f"\n{checked} local links and anchors checked, page budget {PAGE_BUDGET_KB} KB.\n")
            for p in problems:
                f.write(f"- ❌ {p}\n")
    for p in problems:
        print(f"::error::{p}")
    print(f"{len(pages)} pages, {checked} local links checked, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
