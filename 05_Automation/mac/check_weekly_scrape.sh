#!/bin/bash
# =============================================================================
# Script   : check_weekly_scrape.sh
# Layer    : Automation (Mac)
# Purpose  : Missed-scrape alert. Shows a notification when nothing has been
#            uploaded for more than MAX_AGE_DAYS (the Mac was off, Claude was
#            logged out, or the weekly run failed), with the command to run.
# When     : Daily and at login, by launchd (com.mcm.scrape-watchdog.plist).
# Reads    : 06_Datasets/logs/last_upload (written by run_weekly_scrape.sh)
# Settings : MAX_AGE_DAYS  days without an upload before alerting (default: 7)
# =============================================================================

set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/../.." && pwd)"
DATA_DIR="$PROJECT/06_Datasets"
MARKER="$DATA_DIR/logs/last_upload"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-7}"
RUNNER="$PROJECT/05_Automation/mac/run_weekly_scrape.sh"

notify() { osascript -e "display notification \"$2\" with title \"MCM weekly scrape\" subtitle \"$1\"" >/dev/null 2>&1 || true; }

LAST="$(cat "$MARKER" 2>/dev/null || echo "")"
if [[ -n "$LAST" ]]; then
    AGE_DAYS=$(( ( $(date +%s) - $(date -j -f %Y-%m-%d "$LAST" +%s) ) / 86400 ))
    (( AGE_DAYS <= MAX_AGE_DAYS )) && exit 0
    WHEN="Last upload $LAST ($AGE_DAYS days ago)."
else
    WHEN="No upload recorded yet."
fi

# A raw file without its CSV means the scrape ran but extraction is waiting for Claude.
WAITING=""
for RAW in "$DATA_DIR"/MCM_All_products_*_raw.jsonl; do
    [[ -e "$RAW" && ! -e "${RAW%_raw.jsonl}.csv" ]] && WAITING="$RAW"
done

if [[ -n "$WAITING" ]]; then
    notify "Scrape waiting for Claude" "$WHEN Log in to Claude, then run: $RUNNER --resume"
else
    notify "Scrape missed" "$WHEN Run: $RUNNER"
fi
