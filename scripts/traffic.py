#!/usr/bin/env python3
"""Keeps GitHub's repo traffic for longer than the 14 days GitHub shows.

Fetches clones, views, referrers and release downloads, merges them into CSV files in
DIR (one row per day, so reruns are safe) and writes a README with the totals.

Usage: GH_TOKEN=... python3 scripts/traffic.py owner/repo DIR
Note: every CI job checks out the repo, and GitHub counts that as a clone."""
import csv
import datetime as dt
import json
import os
import sys
import urllib.request

repo, out = sys.argv[1], sys.argv[2]
token = os.environ["GH_TOKEN"]
today = dt.date.today().isoformat()


def api(path):
    req = urllib.request.Request(f"https://api.github.com/repos/{repo}{path}", headers={
        "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "notchbar-traffic"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def merge(name, header, rows, key_cols=1):
    """Upserts rows into out/name keyed by the first key_cols columns."""
    path = os.path.join(out, name)
    data = {}
    if os.path.exists(path):
        with open(path) as f:
            for row in list(csv.reader(f))[1:]:
                data[tuple(row[:key_cols])] = row
    for row in rows:
        data[tuple(str(c) for c in row[:key_cols])] = [str(c) for c in row]
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(sorted(data.values()))
    return sorted(data.values())


def total(rows, col):
    return sum(int(r[col]) for r in rows)


os.makedirs(out, exist_ok=True)
clones = merge("clones.csv", ["date", "clones", "unique"],
               [(c["timestamp"][:10], c["count"], c["uniques"]) for c in api("/traffic/clones")["clones"]])
views = merge("views.csv", ["date", "views", "unique"],
              [(v["timestamp"][:10], v["count"], v["uniques"]) for v in api("/traffic/views")["views"]])
refs = api("/traffic/popular/referrers")
merge("referrers.csv", ["date", "source", "views", "unique"],
      [(today, r["referrer"], r["count"], r["uniques"]) for r in refs], key_cols=2)
rel = api("/releases?per_page=100")
assets = [(today, r["tag_name"], a["name"], a["download_count"]) for r in rel for a in r["assets"]]
merge("downloads.csv", ["date", "release", "file", "downloads"], assets, key_cols=3)
stats = api("")
merge("stars.csv", ["date", "stars", "forks", "watchers"],
      [(today, stats["stargazers_count"], stats["forks_count"], stats["subscribers_count"])])

downloads = sum(int(a[3]) for a in assets)
latest = rel[0] if rel else None
latest_dl = sum(a["download_count"] for a in latest["assets"]) if latest else 0
days = len(views) or 1
with open(os.path.join(out, "README.md"), "w") as f:
    f.write(f"""# Traffic for {repo}

Updated {today} by the Traffic workflow. GitHub only keeps 14 days, so this branch keeps the rest.

| | All time here | Since |
|---|---:|---|
| App downloads (every release file) | {downloads} | first release |
| Downloads of {latest['tag_name'] if latest else 'latest'} | {latest_dl} | its release |
| Repo page views | {total(views, 1)} ({total(views, 2)} unique by day) | {views[0][0] if views else today} |
| Clones | {total(clones, 1)} ({total(clones, 2)} unique by day) | {clones[0][0] if clones else today} |
| Stars, forks, watchers | {stats['stargazers_count']}, {stats['forks_count']}, {stats['subscribers_count']} | now |

Top sources in the last 14 days: {", ".join(f"{r['referrer']} ({r['count']})" for r in refs) or "none yet"}.

Clones include CI, which checks out the repo in every job, so treat them as an upper bound.
Raw numbers: clones.csv, views.csv, referrers.csv, downloads.csv, stars.csv.
""")
print(f"Saved traffic for {today}: {downloads} downloads, {total(views, 1)} views, {total(clones, 1)} clones")
