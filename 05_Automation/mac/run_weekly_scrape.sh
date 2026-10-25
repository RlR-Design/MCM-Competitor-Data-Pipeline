#!/bin/bash
# =============================================================================
# Script   : run_weekly_scrape.sh
# Layer    : Automation (Mac)
# Purpose  : Runs the scraper, then uploads the run summary and the products CSV
#            to the bucket. The upload of the CSV triggers the pipeline.
#              06_Datasets/MCM_All_products_<YYYY-MM-DD>.csv
#              06_Datasets/MCM_All_products_<YYYY-MM-DD>_run_summary.csv
#            The scraper first saves <name>_raw.jsonl. If Claude is not available
#            for the extraction step, nothing is uploaded: a notification asks to
#            log in to Claude and run --resume.
# When     : Weekly, by launchd: Sunday 21:00 --scrape-only (com.mcm.weekly-scrape.plist),
#            Monday 07:00 --resume (com.mcm.weekly-upload.plist). Can be run by hand.
# Requires : gcloud CLI signed in (gcloud auth login) with write access to the bucket.
#            Claude Code installed and logged in (claude on PATH).
#            04_Scraper/main.py --output <csv> writes the files.
# Usage    : run_weekly_scrape.sh                    scrape, extract, upload
#            run_weekly_scrape.sh --scrape-only      scrape only (raw file + run summary), no upload
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

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/weekly_scrape_$(date +%Y-%m-%d).log"
exec >>"$LOG_FILE" 2>&1

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
notify() { osascript -e "display notification \"$2\" with title \"MCM weekly scrape\" subtitle \"$1\"" >/dev/null 2>&1 || true; }
fail() { log "FAILED: $1"; notify "Failed" "$1 (log: $LOG_FILE)"; exit 1; }

# One run at a time.
mkdir "$LOCK_DIR" 2>/dev/null || fail "another run is in progress ($LOCK_DIR)"
trap 'rmdir "$LOCK_DIR"' EXIT

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
        [[ -e "${CSV%.csv}_raw.jsonl" ]] && fail "$(basename "${CSV%.csv}_raw.jsonl") already exists; today's scrape has run"
        [[ -x "$PYTHON" ]] || fail "Python not found: $PYTHON (set SCRAPER_PYTHON)"
        log "Scraping (no extraction, no upload) to ${CSV%.csv}_raw.jsonl"
        run_scraper --scrape-only
        log "Done: scrape saved; extraction and upload run with --resume"
        notify "Scraped" "$(basename "${CSV%.csv}_raw.jsonl") saved; extraction and upload follow"
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

log "Uploading $(basename "$CSV")"
gcloud storage cp "$CSV" "$UPLOAD_PREFIX/" || fail "upload of the products CSV failed"

date +%Y-%m-%d > "$LOG_DIR/last_upload"
log "Done: $(basename "$CSV") uploaded; the pipeline runs in BigQuery"
notify "Uploaded" "$(basename "$CSV") sent to the pipeline"
