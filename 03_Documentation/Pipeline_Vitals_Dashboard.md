# Pipeline Vitals Dashboard

A bird's-eye view of the whole pipeline: did the last run work, which steps and shops had trouble, how volumes and run times are moving, and what BigQuery costs. Built for the pipeline owner only; it is not a client report.

| | |
|---|---|
| Where | Claude dashboard "Pipeline Vitals" (claude.ai, under Artifacts). Private: only the owner can open it |
| Data | Live queries to BigQuery each time the page opens, through the owner's Google Cloud BigQuery connector |
| Source objects | `mon_*` views in `01_DDL/08_create_monitoring_views.sql` and `01_DDL/12_create_pipeline_monitoring_views.sql` |
| Built | 14 November 2026, with Claude |
| Cost per open | 8 small read-only queries, about 0.5 GiB billed in total (BigQuery bills a 10 MB minimum per table read). Free tier: 1 TiB a month |

---

## Contents

1. [What it shows](#1-what-it-shows)
2. [How it works](#2-how-it-works)
3. [Monitoring views (01_DDL/12)](#3-monitoring-views-01_ddl12)
4. [Status rules](#4-status-rules)
5. [Dashboard queries](#5-dashboard-queries)
6. [Build log](#6-build-log)
7. [Changing the dashboard](#7-changing-the-dashboard)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. What it shows

Top to bottom:

| Section | Shows | Dataset |
|---|---|---|
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
        ▼  8 read-only queries (execute_sql_readonly), run when the page opens
Claude dashboard "Pipeline Vitals"
```

Design decisions:

- **Views, not report tables.** The client report reads `rpt_*` snapshots rebuilt by step 9. Monitoring must still work when step 9 itself fails, so the dashboard reads the `mon_*` views live.
- **One run = one Bronze load.** The logs of steps 4 to 9 carry their own batch ids, so events are attached to a run by time: everything logged from step 1's start, for up to 6 hours, until the next run starts. Manual `CALL`s outside that window belong to no run and still show in Warnings and errors.
- **Steps that did not exist yet** show as Not deployed, not as failures (step 9 was added on 7 November 2026, so the runs of 26 October and 2 November show it as Not deployed).
- **Claude dashboard rather than Data Studio.** The owner chose it on 14 November 2026: it queries BigQuery live without a separate data source per view, opens on a phone, and keeps the client's Data Studio report separate from internal monitoring.

---

## 3. Monitoring views (01_DDL/12)

`01_DDL/12_create_pipeline_monitoring_views.sql`, deployed 14 November 2026. Safe to re-run.

| View | Grain | Built from | Key columns |
|---|---|---|---|
| `mon_pipeline_events` | log event | The six step log tables | `run_batch_id`, `event_at`, `step_no`, `procedure_name`, `event_type`, `severity` (Info, Warning, Error), `details` |
| `mon_pipeline_step_runs` | run x step | `mon_pipeline_events` | `step_no`, `step_name`, `step_status`, `started_at`, `finished_at`, `duration_seconds`, `warnings`, `errors`, `latest_issue` |
| `mon_pipeline_runs` | run | `mon_pipeline_step_runs`, `mon_scrape_runs`, both validity logs | `pipeline_status`, steps completed / with warnings / failed, `scrape_status`, shops per status, `products_in_csv`, quarantined rows, `silver_rows_changed`, `price_changes`, `reconciliation_issues`, `pipeline_minutes`, `scrape_minutes`, `days_since_previous_run`, `is_latest_run` |
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
| Step: Not deployed | Its procedure had never logged anything before this run |
| Run: Healthy / Completed with warnings / Incomplete / Failed | Failed if any step failed; Incomplete if a deployed step did not run; Completed with warnings if any step had warnings |
| Shop: Fresh / Stale / Critical | Fresh: latest scrape not FAILED. Stale: 1 failed scrape in a row. Critical: 2 or more in a row, or never scraped cleanly |
| Overall health (dashboard header) | Needs attention: run Failed or Incomplete, a shop Critical, or last run more than 8 days ago. Watch: run completed with warnings, scrape not HEALTHY, or a shop Stale. Healthy: none of these |
| Next run date | The next Monday (the pipeline runs on Mondays at 07:00 after the Sunday 21:00 scrape) |

---

## 5. Dashboard queries

All run with `execute_sql_readonly` on project `statement-competitor-pipeline`, timeout 110 seconds. Each dataset reads the BigQuery answer with the dashboard's BigQuery reader (`read.bigquery`). The full SQL is visible and editable in the dashboard's Sources panel; this table records what each one does.

| Dataset | Reads | Rows | Feeds |
|---|---|---|---|
| `vitals` | `mon_pipeline_runs` (latest), `mon_shop_freshness`, `mon_query_costs` (this month), `rpt_market_products` | 1 | Header, tiles |
| `steps` | `mon_pipeline_step_runs` for the last 12 runs | 9 per run | Step strip, step history grid |
| `shopruns` | `mon_scrape_shop_runs` for the last 12 runs | shop x run | Scrape history grid |
| `runs` | `mon_pipeline_runs` | 1 per run | Run trends, products change |
| `shops` | `mon_shop_freshness` | 1 per shop | Shop freshness table |
| `events` | `mon_pipeline_events` where severity is not Info | up to 40 | Warnings and errors |
| `costs` | `mon_query_costs` grouped by week | week x source | GiB per week chart |
| `layers` | `mon_warehouse_tables` grouped by layer | 1 per layer | Tables per layer |

Calculated on the page (shown in Sources as Formula):

- `products_change`: products in the latest run minus the run before.
- `cost_weeks`: the weekly cost rows pivoted to one column per source.

---

## 6. Build log

### 14 November 2026

1. **Inventory.** Found the existing monitoring: `mon_scrape_runs` and `mon_scrape_shop_runs` (scrape side only), six step log tables with consistent `INFO_STAGE_START` / `INFO_STAGE_COMPLETE` events, two validity logs, `ops_pipeline_trigger_log`. Nothing covered the warehouse steps, shop freshness over time or cost.
2. **Event types.** Listed every `error_type` the procedures write (`02_Stored_Procedures/01` to `08`, `11`) to define the Info / Warning / Error rule. All `*_FAILURE` types are procedure crashes except `SCRAPE_FAILURE`, which step 8 logs as a finding.
3. **Views.** Wrote `01_DDL/12_create_pipeline_monitoring_views.sql` (six views) and deployed it.
4. **Verification against known runs.** 3 runs. 26 October and 2 November: Healthy, 8 of 8 deployed steps, 930 products. 9 November: Completed with warnings, 9 of 9 steps, scrape FAILED (4 of 10 shops), 513 products, 6 shops Stale (4 rate limited with HTTP 429, 2 blocked with HTTP 403), 1 reconciliation finding, 7 price changes. Every event mapped to a step; 2 events belong to no run (the manual report refresh of 7 November). BigQuery use over 90 days: 23.9 GiB, well inside the free tier.
5. **Where to build.** A Data Studio report was started first (empty report "SCP Ops - Pipeline vitals" with `mon_pipeline_runs` attached). The owner then chose a Claude dashboard instead. The empty Data Studio report can be deleted.
6. **Dashboard.** Created "Pipeline Vitals" from the Claude dashboard type: 8 live BigQuery datasets (section 5), page sections as in section 1. Every query was run and checked in BigQuery before it was stored.
7. **Documentation.** This file; `01_DDL/12`; Manual sections 1, 2, 4, 11 and 12.1; README setup and monitoring sections; `00_reset_dataset.sql` header; `07_Tests/pipeline_tests.sql` 1.2 and new 3.10; data dictionary.

Add an entry here for every later change: date, what changed, why.

---

## 7. Changing the dashboard

- **Ask Claude** in a chat for any change by name ("add a chart of HTTP errors per shop", "make the shop table sortable"). The dashboard's page and queries live in the dashboard itself, not in this repository.
- **Edit a query yourself:** open Sources beside the page, open the dataset, edit its query, test, save. A saved earlier version can be restored there.
- **Change a rule** (what counts as Stale, the 6 hour run window, severity): change the view in `01_DDL/12`, re-run the file in BigQuery, then note it in the build log. The dashboard picks it up on its next load.
- **Add a pipeline step:** add it to the `CASE` in `mon_pipeline_events` and to the `steps` list in `mon_pipeline_step_runs`, re-run `01_DDL/12`.
- **Rename or drop a `mon_*` column:** search the dashboard's queries in Sources first; the page reads columns by name.
- Freshness: each query runs when the page is opened or refreshed. Data only changes once a week, so a stale-looking figure is usually the run, not the dashboard.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| A section says "Failed to load" | The query failed in BigQuery | Open Sources, read the error, run the same SQL in DataGrip |
| The page asks to connect or allow BigQuery | The connector is signed out or not yet allowed for this dashboard | Allow it on the page, or reconnect Google Cloud BigQuery in Claude's connector settings |
| A step shows Failed but the run finished | The step logged a `*_FAILURE` event | Read the event in Warnings and errors, then the step's log table |
| A run is missing | Step 1 did not log a start (the trigger never fired) | Check `ops_pipeline_trigger_log` and the Cloud Run function logs |
| Events show under no run | A procedure was called by hand more than 6 hours after step 1, or with no step 1 | Expected for manual runs |
| Last run tile shows more than 8 days | The weekly scrape or upload did not happen | Check the Mac scrape log (`05_Automation/mac/`) and the `incoming/` bucket folder |
| Cost chart empty | Job history not readable with the owner's access | Needs `bigquery.jobs.listAll` on the project (Owner or BigQuery Resource Viewer) |
