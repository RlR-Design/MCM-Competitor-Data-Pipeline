# Automation

Every week the Mac scrapes the shops (spread over Sunday to Wednesday) and on Thursday uploads its two files to the bucket folder `incoming/`. The upload of the products CSV triggers the `statement-pipeline-trigger` Cloud Run function, which calls `sp_run_pipeline` with that file.

```
Mac, launchd, Sunday 21:00 (com.mcm.weekly-scrape)
  run_weekly_scrape.sh --scrape-only
    1. first session: all shops ──► 06_Datasets/MCM_All_products_<Sunday>_raw.jsonl + _run_summary.csv
                                    + _progress.json (where each shop stands) + _status.txt (report)

Mac, launchd, every 2 hours (com.mcm.scrape-sessions)
  run_weekly_scrape.sh --continue
    2. next session: only the shops still open (Shopify: a couple of pages each; failed
       shops: again). Rewrites the four files. Does nothing once the week is finished.

Wednesday: read the report (run_weekly_scrape.sh --status); fix anything that failed.

Mac, launchd, Thursday 19:00 (com.mcm.weekly-upload)
  run_weekly_scrape.sh --resume
    1. extract with Claude     ──► MCM_All_products_<Sunday>.csv   (claude -p; if Claude is unavailable: stop, notify, --resume later)
    2. upload <name>_run_summary.csv ──► gs://statement_competitor_data_warehouse/incoming/   (first)
    3. upload <name>.csv             ──► gs://statement_competitor_data_warehouse/incoming/   (last)
                                              │ object finalized event (Eventarc)
                                              ▼
                              statement-pipeline-trigger ──► CALL sp_run_pipeline('gs://…/incoming/<name>.csv')
```

Mac, launchd (daily 10:00 and at login): `check_weekly_scrape.sh` alerts when a Sunday scrape or a Thursday upload was missed, and on Wednesday shows the week's status.

**Why over the week:** since 2026-11 Shopify serves its product feed (`/products.json`, the whole catalogue including sold items) only a couple of pages per shop before refusing for an hour or more. The big Shopify shops need up to ~20 pages, so they are read a few pages per session, each continuing where the last stopped. Each Shopify shop finishes with a completeness check against its product sitemap; products missed because pages shifted are read one by one. See `03_Documentation/scraper_error_log.md`.

| Setting | Value |
|---|---|
| Project | `statement-competitor-pipeline` |
| Bucket | `statement_competitor_data_warehouse` |
| Trigger folder | `incoming/` (files elsewhere in the bucket never trigger a run) |
| Region / BigQuery location | `us-east1` |

## Rules for uploads

- **Run summary first, products CSV last.** The function fires on the products CSV and the pipeline reads the summary straight away; a summary that arrives later is logged as `RUN_SUMMARY_MISSING`.
- **Dated file names**, e.g. `MCM_All_products_2026-10-27.csv`. A fixed name overwrites last week's raw file.
- **Upload each file once.** Every new upload, even of the same name, is a new object version and runs the pipeline.
- **Manual or test files** go outside `incoming/` (e.g. the bucket root) and are run with `CALL sp_run_pipeline(...)`.

---

## Part A: Deploy the trigger function (one-off)

Run in **Cloud Shell**: Google Cloud console → `>_` (top right). Nothing needs installing.

### A1. Get the code and set variables

```bash
git clone https://github.com/RlR-Design/MCM-Competitor-Data-Pipeline.git
cd MCM-Competitor-Data-Pipeline

PROJECT=statement-competitor-pipeline
BUCKET=statement_competitor_data_warehouse
DATASET=statement_competitor_data_warehouse
REGION=us-east1
BQ_LOCATION=us-east1
gcloud config set project $PROJECT
```

Cloud Shell forgets variables when it restarts. If a later command complains about an empty value, set them again.

### A2. Enable the services

```bash
gcloud services enable cloudfunctions.googleapis.com run.googleapis.com \
  eventarc.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  pubsub.googleapis.com bigquery.googleapis.com logging.googleapis.com
```

Takes a minute or two. `01_DDL/09_create_automation_tables.sql` must have been run.

### A3. Check the bucket location

```bash
gcloud storage buckets describe gs://$BUCKET --format="value(location)"
```

- `US-EAST1`: continue.
- `US` (multi-region): continue, and add `--trigger-location=us` to the deploy command in A5.
- Anything else: set `REGION` to that region in lower case. `BQ_LOCATION` stays `us-east1`.

### A4. Service account and permissions

```bash
gcloud iam service-accounts create pipeline-trigger --display-name="Statement pipeline trigger"
SA=pipeline-trigger@$PROJECT.iam.gserviceaccount.com

# Run BigQuery jobs and read/write the dataset.
gcloud projects add-iam-policy-binding $PROJECT --member=serviceAccount:$SA --role=roles/bigquery.jobUser
gcloud projects add-iam-policy-binding $PROJECT --member=serviceAccount:$SA --role=roles/bigquery.dataEditor

# Read the scrape files (LOAD DATA runs as this account).
gcloud storage buckets add-iam-policy-binding gs://$BUCKET --member=serviceAccount:$SA --role=roles/storage.objectViewer

# Receive Eventarc events.
gcloud projects add-iam-policy-binding $PROJECT --member=serviceAccount:$SA --role=roles/eventarc.eventReceiver

# Let Cloud Storage publish events.
PROJECT_NUMBER=$(gcloud projects describe $PROJECT --format='value(projectNumber)')
GCS_AGENT=service-$PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com
gcloud projects add-iam-policy-binding $PROJECT --member="serviceAccount:$GCS_AGENT" --role=roles/pubsub.publisher

# Eventarc's own service agent (Google creates it on first use; grant the role so A5 does not wait for it).
gcloud projects add-iam-policy-binding $PROJECT --member="serviceAccount:service-$PROJECT_NUMBER@gcp-sa-eventarc.iam.gserviceaccount.com" --role=roles/eventarc.serviceAgent

# Build the function (new projects build with the default compute account, without build rights).
gcloud projects add-iam-policy-binding $PROJECT --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" --role=roles/cloudbuild.builds.builder
```

If a command asks to choose a condition, choose `None`. Permissions can take a few minutes to apply: if A5 fails on permissions, wait and run it again.

### A5. Deploy

```bash
gcloud functions deploy statement-pipeline-trigger \
  --gen2 --runtime=python312 --region=$REGION \
  --source=05_Automation/pipeline_trigger --entry-point=on_csv_uploaded \
  --trigger-bucket=$BUCKET \
  --service-account=$SA --trigger-service-account=$SA \
  --timeout=540s --memory=256Mi --max-instances=1 --concurrency=1 \
  --set-env-vars=DATASET=$DATASET,BQ_LOCATION=$BQ_LOCATION,TRIGGER_PREFIX=incoming/

gcloud functions add-invoker-policy-binding statement-pipeline-trigger \
  --region=$REGION --member=serviceAccount:$SA
```

The first deploy takes 2 to 4 minutes. Do not add `--retry`: a failed run must be investigated, not repeated.

### A6. Email alert on failure

Done in the Console, not the terminal (the query is not a shell command). Console → **Logging → Logs Explorer**, paste into the query box:

```
resource.type="cloud_run_revision"
resource.labels.service_name="statement-pipeline-trigger"
severity>=ERROR
```

Run the query, then **Actions → Create log alert**: name `Pipeline failed`, notification channel = your email (create it when asked). Catches failed pipeline runs and function crashes.

### A7. Check it is live

```bash
gcloud functions describe statement-pipeline-trigger --region=$REGION --format="value(state)"
```

Expect `ACTIVE`. The real test is the first upload (Part B, step B3).

---

## Part B: Weekly scrape on the Mac (one-off)

### B1. Install and sign in to the Google Cloud CLI

In Terminal:

```bash
brew install --cask google-cloud-sdk
gcloud auth login
gcloud config set project statement-competitor-pipeline
```

`gcloud auth login` opens the browser; sign in with the Google account that owns the project. The sign-in is kept, so the weekly job runs unattended.

### B2. Make the scripts executable, create the log folder, install the scraper packages

```bash
cd ~/DataGripProjects/Statement-Competitor-Pipeline
chmod +x 05_Automation/mac/run_weekly_scrape.sh 05_Automation/mac/check_weekly_scrape.sh
mkdir -p 06_Datasets/logs
.venv/bin/python -m pip install requests beautifulsoup4
[ -e 04_Scraper/shops_config.py ] || cp 04_Scraper/shops_config.example.py 04_Scraper/shops_config.py   # new setup only; then fill in the real shops
```

### B2b. Claude Code for the extraction step

The scraper fills category, maker, material, era, condition and dimensions with Claude Code in headless mode (`claude -p`). No API key is used: it runs on the Claude login of this Mac and counts toward that plan's usage.

- `claude --version` must work in Terminal, and Claude Code must be logged in on Thursday evenings.
- If Claude is not available, the scrape is still saved (`<name>_raw.jsonl`), nothing is uploaded and a "Waiting for Claude" notification appears. Log in, then run:

```bash
05_Automation/mac/run_weekly_scrape.sh --resume
```

Optional settings: `EXTRACT_MODEL` (model for `claude --model`), `EXTRACT_BATCH` (products per call, default 20), `CLAUDE_BIN` (path to `claude`). Extractions are cached in `06_Datasets/extraction_cache.json`; only new or changed listings are sent.

### B3. Test the upload (this runs the pipeline)

Uploads a CSV (and its run summary, if present) to `incoming/`, exactly as the weekly job does:

```bash
05_Automation/mac/run_weekly_scrape.sh --upload-only 06_Datasets/MCM_All_products_<YYYY-MM-DD>.csv
```

Every upload becomes part of the history. In a clean warehouse, test with the first real scrape only. An older or test CSV loaded first makes every product missing from the next scrape look sold. The first real upload can also simply be the Thursday 19:00 job, or `launchctl start com.mcm.weekly-upload` once the week's scrape has finished (B4).

Then:

- Notification "Uploaded" appears; the log is `06_Datasets/logs/weekly_scrape_<today>.log`.
- Within a minute: `gcloud functions logs read statement-pipeline-trigger --region=us-east1 --limit=20` shows `Starting pipeline for …` and then `Pipeline COMPLETED for …`.
- In DataGrip: `SELECT * FROM statement_competitor_data_warehouse.ops_pipeline_trigger_log;` has one row, and the after-run checks pass.

### B4. Switch on the weekly schedule

Three jobs: Sunday 21:00 starts the week (about 45 minutes, no upload); every 2 hours a session reads what is still open (a few minutes; nothing once the week is finished); Thursday 19:00 extracts with Claude and uploads.

```bash
cd ~/DataGripProjects/Statement-Competitor-Pipeline
cp 05_Automation/mac/com.mcm.weekly-scrape.plist 05_Automation/mac/com.mcm.scrape-sessions.plist 05_Automation/mac/com.mcm.weekly-upload.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.mcm.weekly-scrape.plist
launchctl load -w ~/Library/LaunchAgents/com.mcm.scrape-sessions.plist
launchctl load -w ~/Library/LaunchAgents/com.mcm.weekly-upload.plist
launchctl list | grep com.mcm
```

All jobs listed = scheduled. If `load` says `Input/output error`, `unload` the plist and load it again.

Optional: run them by hand. Not on a Sunday before 21:00: the scheduled scrape would then stop, because today's week has already started.

```bash
launchctl start com.mcm.weekly-scrape
launchctl start com.mcm.weekly-upload
```

### B5. Make sure the Mac is awake

The jobs run under your macOS user: you must be signed in (a locked screen is fine). launchd runs a missed job when the Mac wakes from sleep, but not if it was switched off. To wake (or power on) the Mac every Sunday at 20:55 for the scrape:

```bash
sudo pmset repeat wakeorpoweron U 20:55:00
pmset -g sched        # shows the schedule
```

`pmset repeat` holds one wake time, so the 2-hourly sessions and the Thursday 19:00 upload run on time if the Mac is awake, otherwise as soon as it wakes. A session missed during sleep just runs later (the scrape has until Thursday). Claude Code must be logged in by Thursday 19:00. Keep the Mac plugged in on Sunday evenings.

- The script keeps the Mac from idle sleep while it runs (`caffeinate`), so a scrape is not cut off halfway. A closed lid (without an external display) still sleeps the Mac: leave the lid open.
- Sleep is better than shut down. After a power-on with FileVault the Mac waits at the login screen, and the jobs only run once you have logged in.
- A run that was cut off (crash, power cut) leaves a lock; the next run removes it when that run is no longer alive.

### B6. Watchdog and the Wednesday check

Checks every day at 10:00 and at login, and shows a notification with the command to run:

- "Scrape missed": no week started in the last 8 days (Mac off on Sunday, run failed at the start).
- "Upload missed": the week is not uploaded by Friday (Mac asleep on Thursday, Claude logged out).
- "Wednesday check": the week's status, e.g. "Result: 10 of 10 shops complete. Ready for the upload."

```bash
cd ~/DataGripProjects/Statement-Competitor-Pipeline
cp 05_Automation/mac/com.mcm.scrape-watchdog.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.mcm.scrape-watchdog.plist
```

### The Wednesday check

```bash
05_Automation/mac/run_weekly_scrape.sh --status
```

prints `06_Datasets/MCM_All_products_<Sunday>_status.txt`: one line per shop with Complete, In progress (Shopify, still reading), Retrying (failed, tried again next session, up to 4 attempts) or FAILED (gave up). A Shopify shop is Complete only when every product in its sitemap was read.

- All Complete: nothing to do; Thursday uploads.
- FAILED: read the log (`06_Datasets/logs/weekly_scrape_<date>.log`), fix the cause, then `run_weekly_scrape.sh --continue --retry-failed` (the shop starts again with new attempts; Shopify shops keep the pages already read).
- Still In progress on Thursday 19:00: the upload goes ahead and sends that shop as PARTIAL (its products load, but none are marked sold or delisted that week).

### Change the day or time

Edit `Weekday` (0 = Sunday, 1 = Monday ... 6 = Saturday), `Hour` and `Minute` in `com.mcm.weekly-scrape.plist` (start of the week) or `com.mcm.weekly-upload.plist` (extract + upload), or `StartInterval` (seconds) in `com.mcm.scrape-sessions.plist`, then reload that job:

```bash
cp 05_Automation/mac/com.mcm.weekly-scrape.plist ~/Library/LaunchAgents/
launchctl unload ~/Library/LaunchAgents/com.mcm.weekly-scrape.plist
launchctl load -w ~/Library/LaunchAgents/com.mcm.weekly-scrape.plist
```

Leave the sessions enough time before the upload (the big Shopify shops need about 2 days of sessions) and update the `pmset` wake time to match the Sunday start.

---

## Operation

| Task | How |
|---|---|
| See what ran | Mac: `06_Datasets/logs/`. Cloud: `ops_pipeline_trigger_log`, `gcloud functions logs read statement-pipeline-trigger --region=us-east1` |
| A run failed | Email alert (cloud) or "Failed" notification (Mac). Read the log, fix, then re-run (below) |
| Re-run a file already uploaded | `CALL sp_run_pipeline('gs://statement_competitor_data_warehouse/incoming/<file>.csv')` in DataGrip. The trigger never re-runs a file it has handled |
| Upload by hand | `05_Automation/mac/run_weekly_scrape.sh --upload-only <csv>` |
| Extraction waiting for Claude | Log in to Claude Code, then `05_Automation/mac/run_weekly_scrape.sh --resume` |
| Week's status | `05_Automation/mac/run_weekly_scrape.sh --status` |
| A shop gave up (FAILED) | Fix the cause, then `05_Automation/mac/run_weekly_scrape.sh --continue --retry-failed` |
| Scrape missed (alert) | `05_Automation/mac/run_weekly_scrape.sh --scrape-only` (starts a week under today's date; sessions continue it) |
| Pause the Mac schedule | `launchctl unload ~/Library/LaunchAgents/com.mcm.weekly-scrape.plist ~/Library/LaunchAgents/com.mcm.scrape-sessions.plist ~/Library/LaunchAgents/com.mcm.weekly-upload.plist` |
| Pause the trigger | `gcloud functions delete statement-pipeline-trigger --region=us-east1` (redeploy with A5) |
| Update the function | `git pull` in Cloud Shell, then re-run A5 |

## Limits

- The function waits up to 500 seconds for the pipeline. A longer run carries on in BigQuery; the function logs a warning and the outcome is in the pipeline logs.
- One run at a time (`--max-instances=1`). Steps 2 to 8 work on the latest batch, so runs must never overlap: upload one products CSV per scrape.
- The Mac script refuses to start a week twice on the same day, and a week's sessions stop once its CSV exists, so a repeated start never uploads a second copy.
