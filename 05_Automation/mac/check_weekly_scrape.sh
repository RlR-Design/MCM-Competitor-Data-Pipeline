#!/bin/bash
# =============================================================================
# Script   : check_weekly_scrape.sh
# Layer    : Automation (Mac)
# Purpose  : Weekly scrape watchdog. Shows a notification when:
#              - no week was started in the last 8 days (Sunday scrape missed:
#                the Mac was off, or the run failed at the start);
#              - a week is not uploaded by the Friday after it (the Thursday
#                upload was missed, or extraction is waiting for Claude);
#              - it is Wednesday: the week's status ("8 of 10 shops complete"),
#                the reminder to read the report before Thursday's upload.
# When     : Daily at 10:00 and at login, by launchd (com.mcm.scrape-watchdog.plist).
# Reads    : 06_Datasets/MCM_All_products_<Sunday>_progress.json / _raw.jsonl
#            (the week has started), .csv (built for the upload), _status.txt
# =============================================================================

set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/../.." && pwd)"
DATA_DIR="$PROJECT/06_Datasets"
RUNNER="$PROJECT/05_Automation/mac/run_weekly_scrape.sh"

notify() { osascript -e "display notification \"$2\" with title \"MCM weekly scrape\" subtitle \"$1\"" >/dev/null 2>&1 || true; }
days_since() { echo $(( ( $(date -j -f %Y-%m-%d "$(date +%Y-%m-%d)" +%s) - $(date -j -f %Y-%m-%d "$1" +%s) ) / 86400 )); }

# Latest week: newest Sunday date with a progress or raw file.
WEEK="$(ls -1 "$DATA_DIR"/MCM_All_products_*_progress.json "$DATA_DIR"/MCM_All_products_*_raw.jsonl 2>/dev/null \
        | sed -E 's/.*MCM_All_products_([0-9]{4}-[0-9]{2}-[0-9]{2})_.*/\1/' | sort -u | tail -1)"
if [[ -z "$WEEK" ]]; then
    notify "Scrape missed" "No weekly scrape found. Run: $RUNNER --scrape-only"
    exit 0
fi
AGE="$(days_since "$WEEK")"
BASE="$DATA_DIR/MCM_All_products_$WEEK"
HEADLINE="$(sed -n 2p "${BASE}_status.txt" 2>/dev/null)"

if (( AGE >= 8 )); then
    notify "Scrape missed" "Last week started $WEEK ($AGE days ago). Run: $RUNNER --scrape-only"
elif (( AGE >= 5 )) && [[ ! -e "${BASE}.csv" ]]; then
    notify "Upload missed" "Week $WEEK is not uploaded. ${HEADLINE} Log in to Claude, then run: $RUNNER --resume"
elif [[ "$(date +%u)" == 3 && ! -e "${BASE}.csv" ]]; then
    notify "Wednesday check, week $WEEK" "${HEADLINE:-No status report yet.} Report: $RUNNER --status"
fi
