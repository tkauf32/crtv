#!/usr/bin/env bash
set -euo pipefail

# Event contract for INPUT_EVENT_CMD:
# - next
# - prev
# - random
# - channel:<index|name|url>
# - url:<url_or_path>
# - quit
#
# This stub maps keyboard input to events so hardware adapters can later
# emit the same lines over stdout.

echo "input-events-stub ready: n=next p=prev r=random 1-9=channel q=quit" >&2

while IFS= read -rsn1 key; do
  case "$key" in
    n) echo "next" ;;
    p) echo "prev" ;;
    r) echo "random" ;;
    q) echo "quit"; exit 0 ;;
    [1-9]) echo "channel:${key}" ;;
  esac
done
