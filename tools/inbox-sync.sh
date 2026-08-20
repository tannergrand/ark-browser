#!/bin/bash
# Pulls feature requests into BACKLOG.md's Inbox.
#
# Two sources: the local requests.jsonl that the in-app sheet always writes, and
# open GitHub issues labelled `feature-request` (which is where a friend's
# request lands). Idempotent — synced ids are recorded in tools/.inbox-synced so
# re-running adds nothing twice.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/inbox_sync.py "$@"
