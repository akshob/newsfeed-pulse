#!/bin/bash
# Pull newsfeed log files from hydrogen to this machine.
# Invoked by launchd every 15 minutes (see tools/pulse-logsync.plist).
#
# --delete-during keeps local in sync with remote (logs older than 30 days
# rotate out on both sides).
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${HOME}/.ssh/id_ed_hydrogen"
REMOTE=akshobg@hydrogen.local:/mnt/butterscotch/newsfeed/logs/
LOCAL="${REPO_ROOT}/logs/"

exec rsync -az --delete-during \
  -e "ssh -i ${KEY} -o ConnectTimeout=10 -o BatchMode=yes" \
  "${REMOTE}" "${LOCAL}"
