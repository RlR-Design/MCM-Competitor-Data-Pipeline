# Pipeline Vitals Dashboard

A bird's-eye view of the whole pipeline: did the last run work, which steps and shops had trouble, how volumes and run times are moving, and what BigQuery costs. Built for the pipeline owner only; it is not a client report.

| | |
|---|---|
| Where | Claude dashboard "Pipeline Vitals" (claude.ai, under Artifacts): the live template. Each Thursday evening a frozen copy, "Pipeline Vitals: run of <date>", is saved beside it (section 7). Private: only the owner can open them |
| Role | Backend monitoring. The client-facing dashboard is the separate Data Studio report, which reads only the `rpt_*` tables |
| Data | Live queries to BigQuery each time the page opens, through the owner's Google Cloud BigQuery connector |
| Source objects | `mon_dash_*` views (`01_DDL/13_create_dashboard_views.sql`), built on the `mon_*` views of `01_DDL/08` and `01_DDL/12`; weekly snapshots in `ops_vitals_snapshots` |
| Built | 14 November 2026, with Claude |
| Cost per open | Template: 10 small read-only queries, about 0.6 GiB billed. Weekly report: 10 reads of the snapshot table, about 0.2 GiB. Weekly snapshot: about 1 GiB. Free tier: 1 TiB a month |

---

## Contents

1. [What it shows](#1-what-it-shows)
2. [How it works](#2-how-it-works)
3. [Monitoring views (01_DDL/12)](#3-monitoring-views-01_ddl12)
4. [Status rules](#4-status-rules)
5. [Dashboard queries](#5-dashboard-queries)
6. [Build log](#6-build-log)
7. [Weekly frozen reports](#7-weekly-frozen-reports)
8. [Changing the dashboard](#8-changing-the-dashboard)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. What it shows

Top to bottom:

| Section | Shows | Dataset |
|---|---|---|
| Mode line | Under the title: Live (the template) or Frozen (a weekly report), with the run and when it was frozen | `report` |
| This week's problems | First block on the page. Every problem in the latest run, most urgent first, each with severity, area, what happened, what to do and a link to the section with the evidence. A summary line counts them and names the area to focus on first. The block's edge turns red for a Critical problem, amber otherwise, green when there are none | `problems` |
| Header | Overall health pill (Healthy, Watch, Needs attention) and one sentence on the latest run: steps completed, shops loaded, scrape date, next scheduled run | `vitals` |
| Vital tiles | Last run (days ago), steps completed, shops scraped, products loaded (with change on the previous run), data quality (rows quarantined, reconciliation findings, price changes), run time (scrape and BigQuery minutes, HTTP errors), BigQuery GiB this month. A coloured edge marks a tile that needs attention | `vitals`, `runs` |
| Latest run, step by step | The nine steps of `sp_run_pipeline` as a strip, each with status and duration | `steps` |
| Step history | Grid of steps x last 12 runs, coloured by status, duration in each cell, details on hover or tap | `steps` |
| Shop freshness | Table per shop: freshness, latest result, last good scrape, days since, failures in a row, products against baseline, short error (HTTP 429 rate limited, HTTP 403 blocked) | `shops` |
| Scrape history per shop | Grid of shops x last 12 runs, coloured by health, products in each cell | `shopruns` |
| Run trends | Products loaded, scrape time, changes landed in Silver, shop results per run | `runs` |
| Warnings and errors | The 40 most recent non-routine log events from all nine steps | `events` |
| Warehouse and cost | Tables, rows and size per layer; GiB queried per week by source (automation, interactive and Data Studio, Claude) | `layers`, `costs` |
| Definitions | Closed panel at the foot explaining every status | none |

Every figure can be traced: the Sources panel beside the page shows each query, its result rows and when it ran, and a CSV download of the rows.

The dashboard shows real shop names, because it reads the warehouse directly. Keep it private (safety rule 6 in the Manual covers committed files; the same care applies to sharing this page).

---

## 2. How it works

```
Step logs (bronze_raw_error_logs ... rpt_refresh_error_logs)
bronze_scrape_health, bronze_scrape_run_summary
bronze_validity_log, silver_validity_log           ┐
INFORMATION_SCHEMA.JOBS_BY_PROJECT, __TABLES__     ┘
        │
        ▼  01_DDL/08 and 01_DDL/12 (views, no data)
mon_scrape_shop_runs, mon_scrape_runs
mon_pipeline_events → mon_pipeline_step_runs → mon_pipeline_runs
mon_shop_freshness, mon_warehouse_tables, mon_query_costs
        │
        ▼  01_DDL/13: one view per dashboard section
mon_dash_vitals, _problems, _steps, _shopruns, _runs, _shops, _events, _costs, _layers
        │                                   │
        │ live, each time the page opens    │ Thursday: sp_snapshot_pipeline_vitals
        ▼                                   ▼
Claude dashboard "Pipeline Vitals"     ops_vitals_snapshots (one JSON set per run)
(the template)                              │
                                            ▼ read by
                                  "Pipeline Vitals: run of <date>" (frozen weekly report)
```

Design decisions:

- **Views, not report tables.** The client report reads `rpt_*` snapshots rebuilt by step 9. Monitoring must still work when step 9 itself fails, so the dashboard reads the `mon_*` views live.
- **One run = one Bronze load.** The logs of steps 4 to 9 carry their own batch ids, so events are attached to a run by time: everything logged from step 1's start, for up to 6 hours, until the next run starts. Steps re-run by hand after that window but before the next run are marked `late_run_batch_id` and count as that run's recovery (status Recovered). Manual `CALL`s before the first run belong to no run and still show in Warnings and errors.
- **Steps that did not exist yet** show as Not deployed, not as failures (step 9 was added on 7 November 2026, so the runs of 26 October and 2 November show it as Not deployed).
- **One view per section.** Since 15 November 2026 every dataset on the page reads a `mon_dash_<dataset id>` view, so the logic lives in the repository, is versioned in git, and can be frozen by one generic procedure.
- **Claude dashboard rather than Data Studio.** The owner chose it on 14 November 2026: it queries BigQuery live without a separate data source per view, opens on a phone, and keeps the client's Data Studio report separate from internal monitoring.

---

## 3. Monitoring views (01_DDL/12)

`01_DDL/12_create_pipeline_monitoring_views.sql`, deployed 14 November 2026. Safe to re-run.

| View | Grain | Built from | Key columns |
|---|---|---|---|
| `mon_pipeline_events` | log event | The six step log tables | `run_batch_id`, `late_run_batch_id`, `event_at`, `step_no`, `procedure_name`, `event_type`, `severity` (Info, Warning, Error), `details` |
| `mon_pipeline_step_runs` | run x step | `mon_pipeline_events` | `step_no`, `step_name`, `step_status`, `original_status`, `recovered_at`, `started_at`, `finished_at`, `duration_seconds`, `warnings`, `errors`, `latest_issue` |
| `mon_pipeline_runs` | run | `mon_pipeline_step_runs`, `mon_scrape_runs`, both validity logs | `pipeline_status`, steps completed / with warnings / failed / recovered, `recovered_steps`, `scrape_status`, shops per status, `products_in_csv`, quarantined rows, `silver_rows_changed`, `price_changes`, `reconciliation_issues`, `pipeline_minutes`, `scrape_minutes`, `days_since_previous_run`, `is_latest_run` |
| `mon_shop_freshness` | shop | `mon_scrape_shop_runs` | `freshness`, `latest_status`, `last_good_scrape_at`, `days_since_good_scrape`, `failed_runs_in_a_row`, `failure_rate_pct`, `latest_error` |
| `mon_warehouse_tables` | table | `__TABLES__` | `layer`, `row_count`, `size_mb`, `last_modified_at` |
| `mon_query_costs` | day x source | `region-us-east1`.INFORMATION_SCHEMA.JOBS_BY_PROJECT (90 days) | `jobs`, `failed_jobs`, `gib_billed`, `est_cost_usd` |

Figures taken from log text: `silver_rows_changed` (step 4 "Rows inserted or changed: N"), `price_changes` and `history_rows_inserted` (step 7 "Records Expired: N, Records Inserted: N"). If those messages change wording, update the regular expressions in `mon_pipeline_runs`.

`mon_query_costs` reads job history in `us-east1`, the dataset's location. Change the region if the dataset ever moves.

---

## 4. Status rules

| Status | Rule |
|---|---|
| Event severity | Info: `INFO_STAGE_START`, `INFO_STAGE_COMPLETE`. Error: any `*_FAILURE` except `SCRAPE_FAILURE` (a procedure crashed). Warning: everything else (`SCRAPE_FAILED`, `SCRAPE_FAILURE`, reconciliation findings) |
| Step: Completed | Started and finished, no warnings |
| Step: Completed with warnings | Finished, logged warnings |
| Step: Failed | Logged an error, or started without finishing |
| Step: Not run | Deployed before this run but never started (an earlier step stopped the run) |
| Step: Recovered | Failed or Not run in the run, then re-run by hand and completed before the next run. `original_status` keeps what happened in the run; `recovered_at` the time of the re-run |
| Step: Not deployed | Its procedure had never logged anything before this run |
| Run: Healthy / Completed with warnings / Recovered / Incomplete / Failed | Failed if any step failed; Incomplete if a deployed step did not run; Recovered if every failed or missed step was re-run by hand; Completed with warnings if any step had warnings |
| Shop: Fresh / Stale / Critical | Fresh: latest scrape not FAILED. Stale: 1 failed scrape in a row. Critical: 2 or more in a row, or never scraped cleanly |
| Overall health (dashboard header) | Needs attention: run Failed or Incomplete, a shop Critical, or last run more than 8 days ago. Watch: run Recovered or completed with warnings, scrape not HEALTHY, or a shop Stale. Healthy: none of these |
| Next run date | The next Thursday, today on a Thursday (the scraper uploads the week's CSV at 19:00 after its sessions from Sunday 21:00, and the upload starts the pipeline) |

---

## 5. Dashboard queries

All run with `execute_sql_readonly` on project `statement-competitor-pipeline`, timeout 110 seconds. In the template each dataset is `SELECT * FROM mon_dash_<id> ORDER BY row_order`; in a weekly report it is `SELECT rows_json FROM ops_vitals_snapshots WHERE run_batch_id = '<run>' AND dataset = '<id>'`. One loader per dataset reads either form: plain rows as they come, or the single `rows_json` column expanded into the same rows. The logic of each section is in its view (`01_DDL/13`); this table records what each one reads.

| Dataset (view `mon_dash_<id>`) | Reads | Rows | Feeds |
|---|---|---|---|
| `vitals` | `mon_pipeline_runs` (latest), `mon_shop_freshness`, `mon_query_costs` (this month), `rpt_market_products` | 1 | Header, tiles |
| `steps` | `mon_pipeline_step_runs` for the last 12 runs | 9 per run | Step strip, step history grid |
| `shopruns` | `mon_scrape_shop_runs` for the last 12 runs | shop x run | Scrape history grid |
| `runs` | `mon_pipeline_runs` | 1 per run | Run trends, products change |
| `shops` | `mon_shop_freshness` | 1 per shop | Shop freshness table |
| `events` | `mon_pipeline_events` where severity is not Info | up to 40 | Warnings and errors |
| `costs` | `mon_query_costs` grouped by week | week x source | GiB per week chart |
| `layers` | `mon_warehouse_tables` grouped by layer | 1 per layer | Tables per layer |
| `problems` | `mon_pipeline_runs` (latest and previous), `mon_pipeline_step_runs`, `mon_scrape_shop_runs`, `mon_shop_freshness`, `mon_pipeline_events` | 1 per problem | This week's problems |
| `report` (no view) | Template: a constant row, mode `live`. Weekly report: the run and snapshot time from `ops_vitals_snapshots`, mode `frozen` | 1 | Mode line |

Calculated on the page (shown in Sources as Formula):

- `products_change`: products in the latest run minus the run before.
- `cost_weeks`: the weekly cost rows pivoted to one column per source.
- `problem_summary`: number of problems per severity, and the area of the most urgent one.

### Problem rules (`mon_dash_problems`)

Every rule looks at the latest run only. Change a rule, threshold or "What to do" text in `01_DDL/13_create_dashboard_views.sql`, re-run the file, and add a build log entry.

| Area | Problem | Severity | Raised when |
|---|---|---|---|
| Schedule | No pipeline run for N days | Critical | Last run more than 8 days ago |
| Warehouse | Step N failed or did not run | Critical | `step_status` Failed or Not run |
| Warehouse | Step N: failed, recovered by hand | Medium | `step_status` Recovered and `original_status` Failed. No action for a one-off BigQuery error |
| Scraper | N shops rate limited (HTTP 429), blocked (HTTP 403), not found (HTTP 404) or other cause | High; Critical if any of them failed two runs or more in a row | Shop `health_status` FAILED, grouped by cause |
| Scraper | N shops scraped with warnings | Medium | Shop `health_status` WARNING |
| Data quality | N rows quarantined | High | Bronze plus Silver quarantined rows above 0 |
| Data quality | Reconciliation finding: TYPE | High | Step 8 warning other than `SCRAPE_FAILURE` (failed scrapes are already listed under Scraper) |
| Warehouse | Step N: warnings | Medium | Warnings from any step except 3 and 8 |
| Volume | Products loaded fell N% | High | Products in the CSV below 80% of the previous run |
| Performance | Scrape took N min, up N% | Medium | Scrape time up more than 25% and at least 5 minutes on the previous run |

Order: severity, then causes before symptoms (Schedule, Warehouse, Scraper, Data quality, Volume, Performance), then size of impact (products affected, minutes added). A volume drop caused by failed shops therefore lists below the scraper problems that caused it.

Each problem carries a fixed "What to do" text. Keep them in line with `scraper_error_log.md` and the Manual as fixes are learnt.

---

## 6. Build log

### 14 November 2026

1. **Inventory.** Found the existing monitoring: `mon_scrape_runs` and `mon_scrape_shop_runs` (scrape side only), six step log tables with consistent `INFO_STAGE_START` / `INFO_STAGE_COMPLETE` events, two validity logs, `ops_pipeline_trigger_log`. Nothing covered the warehouse steps, shop freshness over time or cost.
2. **Event types.** Listed every `error_type` the procedures write (`02_Stored_Procedures/01` to `08`, `11`) to define the Info / Warning / Error rule. All `*_FAILURE` types are procedure crashes except `SCRAPE_FAILURE`, which step 8 logs as a finding.
3. **Views.** Wrote `01_DDL/12_create_pipeline_monitoring_views.sql` (six views) and deployed it.
4. **Verification against known runs.** 3 runs. 26 October and 2 November: Healthy, 8 of 8 deployed steps, 930 products. 9 November: Completed with warnings, 9 of 9 steps, scrape FAILED (6 of 10 shops failed), 513 products, 6 shops Stale (4 rate limited with HTTP 429, 2 blocked with HTTP 403), 1 reconciliation finding, 7 price changes. Every event mapped to a step; 2 events belong to no run (the manual report refresh of 7 November). BigQuery use over 90 days: 23.9 GiB, well inside the free tier.
5. **Where to build.** A Data Studio report was started first (empty report "SCP Ops - Pipeline vitals" with `mon_pipeline_runs` attached). The owner then chose a Claude dashboard instead. The empty Data Studio report can be deleted.
6. **Dashboard.** Created "Pipeline Vitals" from the Claude dashboard type: 8 live BigQuery datasets (section 5), page sections as in section 1. Every query was run and checked in BigQuery before it was stored.
7. **Documentation.** This file; `01_DDL/12`; Manual sections 1, 2, 4, 11 and 12.1; README setup and monitoring sections; `00_reset_dataset.sql` header; `07_Tests/pipeline_tests.sql` 1.2 and new 3.10; data dictionary.

### 14 November 2026, evening

8. **This week's problems.** Added the `problems` dataset and the block at the top of the page, at the owner's request: the first thing on the page should show what went wrong in the week and where to focus. Rules and order as in section 5. For the run of 9 November it lists: 4 shops rate limited (HTTP 429, about 377 products), 2 shops blocked (HTTP 403, about 38 products), products loaded down 45% (930 to 513), scrape time up 45% (63.9 min). Focus first on: Scraper. The overall health line and the vital tiles moved directly below it.

### 15 November 2026

9. **Template and weekly frozen reports**, at the owner's request: the dashboard becomes the template for a frozen report of each week's run, while staying open to change as new problems are found.
   - Moved every dashboard query into a view, `01_DDL/13_create_dashboard_views.sql` (`mon_dash_vitals`, `_problems`, `_steps`, `_shopruns`, `_runs`, `_shops`, `_events`, `_costs`, `_layers`), each with a `row_order` column. Same rows as before; checked view by view.
   - New table `ops_vitals_snapshots` and procedure `sp_snapshot_pipeline_vitals` (`02_Stored_Procedures/12`), which freezes every `mon_dash_` view for the latest run.
   - Template: datasets now read the views; one loader per dataset reads live rows or a frozen snapshot; new `report` dataset and mode line (Live / Frozen).
   - First weekly report: "Pipeline Vitals: run of 9 Nov 2026", from the snapshot of `BATCH_20261109_050245`.
   - Scheduled task "Pipeline Vitals weekly report": Mondays 08:03 SAST (section 7).
10. **Problem advice corrected.** The "What to do" texts for HTTP 429 and 403 still advised a browser User-Agent, which contradicts the scraper fix of 14 November (2.2.0 sends an honest User-Agent; see `scraper_error_log.md`). Rewritten in `mon_dash_problems`, and the 9 November snapshot retaken so its report carries the corrected texts.
11. **Restored documentation.** The edit of this file on the evening of 14 November started from an older copy and dropped the "This week's problems" sections; restored, keeping that edit's Role line and wording.

### 24 November 2026

12. **Run of 16 November recovered.** Step 6 failed with a one-off BigQuery error (`NORMALISATION_MERGE_FAILURE`, "Retrying may solve the problem"), so steps 7 to 9 did not run. Steps 6 to 9 were re-run by hand on 24 November, 08:55 to 08:57; all completed.
13. **Recovered status**, at the owner's request, so a run fixed by hand no longer shows Failed. `mon_pipeline_events` gains `late_run_batch_id` (events after the 6 hour window, before the next run); `mon_pipeline_step_runs` shows Recovered with `original_status` and `recovered_at`; `mon_pipeline_runs` gains Recovered, `steps_recovered`, `recovered_steps` and `recovered_at`. Overall health treats Recovered as Watch; `mon_dash_problems` lists a recovered failure as Medium. Checked: 16 November shows steps 6 to 9 Recovered, 9 of 9 completed; earlier runs unchanged (the manual step 9 of 7 November now attaches to the 2 November run as a late event, but only Failed or Not run steps can be Recovered, so step 9 stays Not deployed there). The 16 November snapshot was retaken, and its report's page updated to colour Recovered.
14. **Thursday schedule.** Scraper 2.4.0 scrapes in sessions from Sunday 21:00 and uploads on Thursday at 19:00, so the pipeline now runs on Thursday evening. Next run date, the overdue text, the weekly report task (now Thursday 21:33 SAST, with a guard against a run still in progress) and this file follow it. The task fired on Monday 23 November and correctly made no report.
15. Removed three stray spaces before this file's title.
16. **Thursday wake.** The Mac slept on weekday evenings, which could miss the 19:00 upload and so the report. Added one-off wakes every Thursday at 18:55 for 52 weeks (`05_Automation/README.md`, B5); the Sunday 20:55 wake is unchanged.

Add an entry here for every later change: date, what changed, why.

---

## 7. Weekly frozen reports

**What they are.** Each Thursday a copy of the template is saved as a separate dashboard, "Pipeline Vitals: run of <date>" (for example "Pipeline Vitals: run of 16 Nov 2026"). It has the template's page as it was that day, and that run's numbers frozen: they never change, however much later runs or fixes change the warehouse. The template stays live and keeps improving; past reports keep the layout they were made with.

**How a week is frozen.**

1. The scraper on the Mac uploads the week's CSV on Thursday at 19:00, which starts the pipeline (step 1 to 9).
2. At 21:33 the scheduled task "Pipeline Vitals weekly report" (claude.ai, scheduled tasks) starts:
   - Checks the latest run is from this week. If not, no report: it tells the owner the pipeline did not run.
   - `CALL sp_snapshot_pipeline_vitals(FALSE)`: copies every `mon_dash_` view into `ops_vitals_snapshots` for that run (one JSON array per view). A second call keeps the existing snapshot.
   - Reads the template's page and datasets, creates the new dashboard, points every `mon_dash_` dataset at the snapshot, sets `report` to mode `frozen`, and copies the page unchanged.
   - Sends the owner a push notification: the run, this week's problems in order, the focus area and the report link.
3. The task runs in the cloud with automatic approval; it reads BigQuery through the owner's Google Cloud BigQuery connector and writes nothing in BigQuery except the snapshot.

**Making one by hand** (for a missed Thursday, or after a manual pipeline run): ask Claude "make this week's Pipeline Vitals report", or run the scheduled task now from its page. Only the latest run can be frozen, so do it before the next run.

**Re-freezing a week.** `CALL sp_snapshot_pipeline_vitals(TRUE)` retakes the snapshot of the latest run (its report shows the new snapshot time). Past runs cannot be re-frozen.

**Improving the reports over time.** Change the template, not the reports. A change reaches every report made after it:

| Change | Where | Frozen next Thursday? |
|---|---|---|
| Wording, layout, a chart drawn from existing data | Template page (ask Claude) | Yes, the page is copied |
| A new problem rule, threshold or "What to do" text | `mon_dash_problems` in `01_DDL/13`, re-run the file | Yes |
| A new section with new data | A new view `mon_dash_<id>` in `01_DDL/13` and a dataset `<id>` in the template reading it | Yes, the procedure freezes every `mon_dash_` view |
| A dataset that does not read a `mon_dash_` view | Template | No: copied as a live query; the task reports it as "not frozen" |

To give an older report a newer layout, ask Claude to copy the template's current page into it; its data stays as frozen.

**Where they are.** claude.ai, Artifacts; all titled "Pipeline Vitals: run of ...". The snapshots themselves:

```sql
SELECT run_batch_id, MIN(taken_at) AS taken_at, COUNT(*) AS datasets, SUM(row_count) AS row_count
FROM statement_competitor_data_warehouse.ops_vitals_snapshots
GROUP BY run_batch_id
ORDER BY taken_at DESC;
```

## 8. Changing the dashboard

- **Ask Claude** in a chat for any change by name ("add a chart of HTTP errors per shop", "make the shop table sortable"). The page lives in the template dashboard; the logic of each section lives in its `mon_dash_` view in `01_DDL/13`.
- **Change the template, not a weekly report.** Every Thursday's report copies the template as it is then (section 7).
- **Change what a section shows:** edit its `mon_dash_` view in `01_DDL/13` and re-run the file. Keep the `row_order` column. Editing a query in the dashboard's Sources panel works for the template, but anything that no longer reads a `mon_dash_` view is not frozen in the weekly reports.
- **Change a rule** (what counts as Stale, the 6 hour run window, severity): change the view in `01_DDL/12`, re-run the file in BigQuery, then note it in the build log. The dashboard picks it up on its next load.
- **Add a pipeline step:** add it to the `CASE` in `mon_pipeline_events` and to the `steps` list in `mon_pipeline_step_runs`, re-run `01_DDL/12`.
- **Rename or drop a `mon_*` column:** search the dashboard's queries in Sources first; the page reads columns by name.
- Freshness: each query runs when the page is opened or refreshed. Data only changes once a week, so a stale-looking figure is usually the run, not the dashboard.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| A section says "Failed to load" | The query failed in BigQuery | Open Sources, read the error, run the same SQL in DataGrip |
| The page asks to connect or allow BigQuery | The connector is signed out or not yet allowed for this dashboard | Allow it on the page, or reconnect Google Cloud BigQuery in Claude's connector settings |
| A step shows Failed but the run finished | The step logged a `*_FAILURE` event | Read the event in Warnings and errors, then the step's log table |
| A run is missing | Step 1 did not log a start (the trigger never fired) | Check `ops_pipeline_trigger_log` and the Cloud Run function logs |
| Events show under no run | A procedure was called by hand before the first run | Expected. Calls after a run count as its recovery |
| A step shows Recovered | It failed or did not run, and was re-run by hand before the next run | Read the original error in This week's problems; no action if it was a one-off |
| Last run tile shows more than 8 days | The weekly scrape or upload did not happen | Check the week's status file and log in `06_Datasets` on the Mac, and the `incoming/` bucket folder |
| No weekly report on Thursday | The pipeline did not run (the task says so), or the task failed | Open the scheduled task's last run; make the report by hand (section 7) before the next run |
| A weekly report shows Live, or today's numbers | Its datasets were not pointed at the snapshot | Check its `report` dataset and the dataset queries in Sources; remake it |
| Cost chart empty | Job history not readable with the owner's access | Needs `bigquery.jobs.listAll` on the project (Owner or BigQuery Resource Viewer) |
