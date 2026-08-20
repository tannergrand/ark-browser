#!/usr/bin/env python3
"""Append new feature requests to BACKLOG.md's Inbox.

Sources:
  1. ~/Library/Application Support/Ark/requests.jsonl  (the in-app sheet)
  2. open GitHub issues labelled `feature-request`      (via the gh CLI)

Idempotent: every appended item's id is recorded, so a second run is a no-op.
Never edits anything below the Inbox heading's own section, so the Queue and
Shipped lists are safe.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BACKLOG = ROOT / "BACKLOG.md"
SYNCED = ROOT / "tools" / ".inbox-synced"
LOCAL = Path.home() / "Library/Application Support/Ark/requests.jsonl"
REPO = "tannergrand/ark-browser"


def synced_ids():
    if not SYNCED.exists():
        return set()
    return {line.strip() for line in SYNCED.read_text().splitlines() if line.strip()}


def local_requests():
    if not LOCAL.exists():
        return []
    out = []
    for line in LOCAL.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            # One truncated line shouldn't cost the rest of the file. This is why
            # the app appends JSONL rather than rewriting a JSON array.
            continue
        if row.get("title"):
            out.append({
                "id": "local:" + row.get("id", ""),
                "title": row["title"].strip(),
                "detail": (row.get("detail") or "").strip(),
                "source": "in-app",
            })
    return out


def github_requests():
    if not shutil_which("gh"):
        return []
    try:
        raw = subprocess.run(
            ["gh", "issue", "list", "--repo", REPO, "--label", "feature-request",
             "--state", "open", "--limit", "100", "--json", "number,title,body,author"],
            capture_output=True, text=True, timeout=30, check=True).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return []
    out = []
    for issue in json.loads(raw or "[]"):
        author = (issue.get("author") or {}).get("login", "someone")
        out.append({
            "id": f"gh:{issue['number']}",
            "title": issue["title"].strip(),
            "detail": (issue.get("body") or "").strip(),
            "source": f"@{author}, #{issue['number']}",
        })
    return out


def shutil_which(name):
    from shutil import which
    return which(name)


def first_line(text, limit=180):
    line = " ".join(text.split())
    return line[:limit] + ("…" if len(line) > limit else "")


def main():
    seen = synced_ids()
    incoming = [r for r in local_requests() + github_requests() if r["id"] not in seen]
    if not incoming:
        print("inbox is up to date")
        return 0

    text = BACKLOG.read_text()
    match = re.search(r"(## Inbox\n\n.*?\n\n)(.*?)(\n---)", text, re.S)
    if not match:
        print("could not find the Inbox section in BACKLOG.md", file=sys.stderr)
        return 1

    body = match.group(2).rstrip("\n")
    # A lone "-" placeholder is dropped once there's something real.
    if body.strip() == "-":
        body = ""
    lines = [body] if body else []
    for request in incoming:
        entry = f"- **{request['title']}** — {request['source']}"
        if request["detail"]:
            entry += f". {first_line(request['detail'])}"
        lines.append(entry)

    # The trailing newline matters: without it the section's --- ends up flush
    # against the last bullet.
    updated = text[:match.start(2)] + "\n".join(lines) + "\n" + text[match.end(2):]
    BACKLOG.write_text(updated)

    with SYNCED.open("a") as handle:
        for request in incoming:
            handle.write(request["id"] + "\n")

    print(f"added {len(incoming)} request(s) to the Inbox")
    return 0


if __name__ == "__main__":
    sys.exit(main())
