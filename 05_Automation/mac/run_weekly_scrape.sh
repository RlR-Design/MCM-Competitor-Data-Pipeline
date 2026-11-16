#!/bin/bash
# =============================================================================
# Script   : run_weekly_scrape.sh
# Layer    : Automation (Mac)
# Purpose  : The weekly scrape, spread over the week, then one upload. The upload
#            of the CSV triggers the pipeline.
#              06_Datasets/MCM_All_products_<Sunday>.csv
#              06_Datasets/MCM_All_products_<Sunday>_run_summary.csv
#            While the week runs, every session also rewrites <name>_raw.jsonl,
#            <name>_progress.json and <name>_status.txt (the readable report).
#            If Claude is not available for the extraction step, nothing is
#            uploaded: a notification asks to log in to Claude and run --resume.
# When     : By launchd:
#              Sunday 21:00     --scrape-only   starts the week (com.mcm.weekly-scrape.plist)
#              every 2 hours    --continue      reads what is still open; does nothing when
#                                               the week is finished or uploaded
#                                               (com.mcm.scrape-sessions.plist)
#              Thursday 19:00   --resume        extracts with Claude and uploads
#                                               (com.mcm.weekly-upload.plist)
#            Check the report on Wednesday: run_weekly_scrape.sh --status
# Requires : gcloud CLI signed in (gcloud auth login) with write access to the bucket.
#            Claude Code installed and logged in (claude on PATH).
#            04_Scraper/main.py --output <csv> writes the files.
# Usage    : run_weekly_scrape.sh                    scrape (one session), extract, upload
#            run_weekly_scrape.sh --scrape-only      start the week: first session, no upload
#            run_weekly_scrape.sh --continue [--retry-failed]
#                                                    next session for the open week; --retry-failed
#                                                    gives shops that gave up new attempts (after a fix)
#            run_weekly_scrape.sh --status           print the open (or latest) week's report
#            run_weekly_scrape.sh --resume [<csv>]   extract from a saved raw file, then upload
#                                                    (default: the latest raw file without a CSV)
#            run_weekly_scrape.sh --upload-only <csv> upload an existing CSV (and its summary)
# Settings : SCRAPER_PYTHON  Python to run the scraper (default: <project>/.venv/bin/python)
#            UPLOAD_PREFIX   Bucket folder (default: gs://statement_competitor_data_warehouse/incoming)
# Writes   : 06_Datasets/logs/last_upload  date of the last successful upload (read by
#            check_weekly_scrape.sh)
# Warning  : Every upload is loaded by the pipeline. Upload each file once.
# =============================================================================

set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHON="${SCRAPER_PYTHON:-$PROJECT/.venv/bin/python}"
UPLOAD_PREFIX="${UPLOAD_PREFIX:-gs://statement_competitor_data_warehouse/incoming}"
DATA_DIR="$PROJECT/06_Datasets"
LOG_DIR="$DATA_DIR/logs"
LOCK_DIR="$LOG_DIR/.run.lock"
SELF="$PROJECT/05_Automation/mac/run_weekly_scrape.sh"

# launchd starts with a minimal PATH; add the usual gcloud and claude locations.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/local/share/google-cloud-sdk/bin:$HOME/google-cloud-sdk/bin:$HOME/.local/bin:$HOME/.claude/local:$PATH"

# The open week: the latest progress file whose CSV has not been written yet.
open_week_csv() {
    local P
    for P in $(ls -1r "$DATA_DIR"/MCM_All_products_*_progress.json 2>/dev/null); do
        [[ -e "${P%_progress.json}.csv" ]] || { echo "${P%_progress.json}.csv"; return; }
    done
}

case "${1:-}" in
    --status)
        CSV="$(open_week_csv)"
        if [[ -z "$CSV" ]]; then
            P="$(ls -1r "$DATA_DIR"/MCM_All_products_*_progress.json 2>/dev/null | head -1)"
            [[ -n "$P" ]] || { echo "No weekly scrape found in $DATA_DIR"; exit 1; }
            CSV="${P%_progress.json}.csv"
            echo "(This week has been uploaded: $(basename "$CSV"))"
        fi
        cat "${CSV%.csv}_status.txt" 2>/dev/null || echo "No status report yet for $(basename "$CSV")"
        exit 0
        ;;
    --continue)
        # Every 2 hours: leave quietly (no log, no lock) when there is nothing to read.
        CSV="$(open_week_csv)"
        [[ -n "$CSV" ]] || exit 0
        if [[ "${2:-}" != "--retry-failed" ]]; then
            grep -q '"finished": true' "${CSV%.csv}_progress.json" && exit 0
        fi
        ;;
esac

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/weekly_scrape_$(date +%Y-%m-%d).log"
exec >>"$LOG_FILE" 2>&1

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
notify() { osascript -e "display notification \"$2\" with title \"MCM weekly scrape\" subtitle \"$1\"" >/dev/null 2>&1 || true; }
fail() { log "FAILED: $1"; notify "Failed" "$1 (log: $LOG_FILE)"; exit 1; }

# One run at a time. A lock left by a run that died (crash, power cut) is taken over.
# A 2-hourly session that finds a run in progress just skips; the others wait up to 30 min.
WAITED=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    OLD_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        [[ "${1:-}" == "--continue" ]] && { log "Session skipped: another run is in progress (pid $OLD_PID)"; exit 0; }
        (( WAITED >= 1800 )) && fail "another run is in progress (pid $OLD_PID, $LOCK_DIR)"
        (( WAITED == 0 )) && log "Waiting for another run to finish (pid $OLD_PID)"
        sleep 60; WAITED=$(( WAITED + 60 ))
        continue
    fi
    log "Removing stale lock (pid ${OLD_PID:-unknown} is not running)"
    rm -rf "$LOCK_DIR"
done
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# Keep the Mac awake (no idle sleep) while this script runs.
caffeinate -i -w $$ &

log "Start (project: $PROJECT)"

# Runs main.py; exit 2 means the scrape is saved but extraction is waiting for Claude.
run_scraper() {
    "$PYTHON" "$PROJECT/04_Scraper/main.py" --output "$CSV" "$@"
    local rc=$?
    if [[ $rc -eq 2 ]]; then
        log "WAITING: extraction pending (Claude not available). Raw data saved."
        notify "Waiting for Claude" "Log in to Claude, then run: $SELF --resume"
        exit 2
    fi
    [[ $rc -eq 0 ]] || fail "scraper exited with an error ($rc)"
}

case "${1:-}" in
    --upload-only)
        CSV="${2:-}"
        [[ -n "$CSV" ]] || fail "--upload-only needs a CSV path"
        ;;
    --resume)
        CSV="${2:-}"
        if [[ -z "$CSV" ]]; then
            for RAW in $(ls -1r "$DATA_DIR"/MCM_All_products_*_raw.jsonl 2>/dev/null); do
                [[ -e "${RAW%_raw.jsonl}.csv" ]] || { CSV="${RAW%_raw.jsonl}.csv"; break; }
            done
            [[ -n "$CSV" ]] || fail "no raw file waiting for extraction in $DATA_DIR"
        fi
        [[ -e "$CSV" ]] && fail "$(basename "$CSV") already exists; it may have been uploaded already"
        [[ -x "$PYTHON" ]] || fail "Python not found: $PYTHON (set SCRAPER_PYTHON)"
        log "Resuming extraction for $CSV"
        run_scraper --resume
        ;;
    --scrape-only)
        CSV="$DATA_DIR/MCM_All_products_$(date +%Y-%m-%d).csv"
        [[ -e "${CSV%.csv}_progress.json" || -e "${CSV%.csv}_raw.jsonl" ]] && fail "today's scrape has started already ($(basename "${CSV%.csv}")_*)"
        [[ -x "$PYTHON" ]] || fail "Python not found: $PYTHON (set SCRAPER_PYTHON)"
        log "Starting the week: first session (no extraction, no upload) for $(basename "$CSV")"
        run_scraper --scrape-only
        log "Done: first session saved; sessions every 2 hours continue; upload Thursday 19:00"
        notify "Week started" "$(head -2 "${CSV%.csv}_status.txt" | tail -1)"
        exit 0
        ;;
    --continue)
        [[ -x "$PYTHON" ]] || fail "Python not found: $PYTHON (set SCRAPER_PYTHON)"
        log "Session for $(basename "$CSV")${2:+ ($2)}"
        run_scraper --continue ${2:+"$2"}
        if grep -q '"finished": true' "${CSV%.csv}_progress.json"; then
            log "Week finished: $(head -2 "${CSV%.csv}_status.txt" | tail -1)"
            notify "Week's scrape finished" "$(head -2 "${CSV%.csv}_status.txt" | tail -1)"
        fi
        exit 0
        ;;
    *)
        CSV="$DATA_DIR/MCM_All_products_$(date +%Y-%m-%d).csv"
        [[ -e "$CSV" ]] && fail "$(basename "$CSV") already exists; it may have been uploaded already"
        [[ -x "$PYTHON" ]] || fail "Python not found: $PYTHON (set SCRAPER_PYTHON)"
        command -v claude >/dev/null || log "WARNING: claude not found on PATH; extraction will wait"
        log "Scraping to $CSV"
        run_scraper
        ;;
esac

SUMMARY="${CSV%.csv}_run_summary.csv"
[[ -s "$CSV" ]] || fail "products CSV missing or empty: $CSV"
command -v gcloud >/dev/null || fail "gcloud not found (install the Google Cloud CLI)"

# Run summary first: the pipeline reads it as soon as the CSV arrives.
if [[ -s "$SUMMARY" ]]; then
    log "Uploading $(basename "$SUMMARY")"
    gcloud storage cp "$SUMMARY" "$UPLOAD_PREFIX/" || fail "upload of the run summary failed"
else
    log "No run summary found; the pipeline logs RUN_SUMMARY_MISSING"
fi

STATUS_FILE="${CSV%.csv}_status.txt"
[[ -s "$STATUS_FILE" ]] && log "Status at upload: $(head -2 "$STATUS_FILE" | tail -1)"

log "Uploading $(basename "$CSV")"
gcloud storage cp "$CSV" "$UPLOAD_PREFIX/" || fail "upload of the products CSV failed"

date +%Y-%m-%d > "$LOG_DIR/last_upload"
log "Done: $(basename "$CSV") uploaded; the pipeline runs in BigQuery"
notify "Uploaded" "$(basename "$CSV") sent to the pipeline"
