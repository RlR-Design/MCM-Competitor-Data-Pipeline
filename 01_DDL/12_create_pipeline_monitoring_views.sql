/*
===============================================================================
Script   : 12_create_pipeline_monitoring_views.sql
Layer    : Monitoring
Purpose  : Vitals of the whole pipeline, for the Pipeline Vitals report:
             mon_pipeline_events      every log event of every step, classified
             mon_pipeline_step_runs   one row per run per step (steps 1 to 9)
             mon_pipeline_runs        one row per run: status, timings, volumes
             mon_shop_freshness       one row per shop: last good scrape, streaks
             mon_warehouse_tables     row counts and size per table
             mon_query_costs          BigQuery usage and estimated cost per day
           A run starts when sp_load_bronze_products logs INFO_STAGE_START.
           Events from the next 6 hours, until the next run starts, belong to
           that run. Events outside any run (manual CALLs) have no run.
When     : Initial setup, after 11_create_report_tables.sql.
           Re-run after any change to this file. Safe to re-run.
Warning  : Views hold no data. Data Studio reads these views directly, not
           rpt_* snapshots, so the report still shows a run whose step 9 failed.
           mon_query_costs reads region-us-east1 job history: the dataset
           location. Change the region if the dataset moves.
===============================================================================
*/

-- -----------------------------------------------------------------------------
-- mon_pipeline_events: every event from the six step logs.
--   severity  Info     INFO_STAGE_START / INFO_STAGE_COMPLETE
--             Error    a procedure failure (*_FAILURE, except SCRAPE_FAILURE)
--             Warning  anything else (failed shop scrapes, check findings)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_pipeline_events
OPTIONS(description="Every log event of pipeline steps 1 to 9, with step number, severity and the run it belongs to")
AS
WITH events AS (
    SELECT 'Bronze' AS layer, scraper_job_id AS procedure_name, batch_id, execution_id,
           error_type AS event_type, error_details AS details, error_timestamp AS event_at
    FROM statement_competitor_data_warehouse.bronze_raw_error_logs
    UNION ALL
    SELECT 'Silver', scraper_job_id, batch_id, execution_id, error_type, error_details, error_timestamp
    FROM statement_competitor_data_warehouse.silver_transformed_error_logs
    UNION ALL
    SELECT 'Silver', procedure_name, batch_id, execution_id, error_type, error_details, error_timestamp
    FROM statement_competitor_data_warehouse.silver_normalised_error_logs
    UNION ALL
    SELECT 'Silver', procedure_name, batch_id, execution_id, error_type, error_details, error_timestamp
    FROM statement_competitor_data_warehouse.silver_historisation_error_logs
    UNION ALL
    SELECT 'Silver', procedure_name, batch_id, execution_id, error_type, error_details, error_timestamp
    FROM statement_competitor_data_warehouse.silver_reconciled_error_logs
    UNION ALL
    SELECT 'Report', procedure_name, batch_id, execution_id, error_type, error_details, error_timestamp
    FROM statement_competitor_data_warehouse.rpt_refresh_error_logs
),
-- Run spine: each Bronze load start opens a run.
runs AS (
    SELECT
        batch_id AS run_batch_id,
        error_timestamp AS run_started_at,
        LEAD(error_timestamp) OVER (ORDER BY error_timestamp) AS next_run_at
    FROM statement_competitor_data_warehouse.bronze_raw_error_logs
    WHERE scraper_job_id = 'sp_load_bronze_products'
      AND error_type = 'INFO_STAGE_START'
)
SELECT
    r.run_batch_id,
    e.event_at,
    e.layer,
    CASE e.procedure_name
        WHEN 'sp_load_bronze_products' THEN 1
        WHEN 'sp_validate_bronze_products' THEN 2
        WHEN 'sp_check_scrape_health' THEN 3
        WHEN 'sp_load_silver_products' THEN 4
        WHEN 'sp_validate_silver_products' THEN 5
        WHEN 'sp_normalise_silver_products' THEN 6
        WHEN 'sp_load_dim_price_history' THEN 7
        WHEN 'sp_reconciled_silver_products' THEN 8
        WHEN 'sp_refresh_report_tables' THEN 9
    END AS step_no,
    e.procedure_name,
    e.event_type,
    CASE
        WHEN e.event_type LIKE 'INFO\\_%' THEN 'Info'
        WHEN e.event_type LIKE '%\\_FAILURE' AND e.event_type != 'SCRAPE_FAILURE' THEN 'Error'
        ELSE 'Warning'
    END AS severity,
    e.details,
    e.batch_id AS log_batch_id,
    e.execution_id
FROM events e
LEFT JOIN runs r
    ON e.event_at >= r.run_started_at
   AND (e.event_at < r.next_run_at OR r.next_run_at IS NULL)
   AND e.event_at < TIMESTAMP_ADD(r.run_started_at, INTERVAL 6 HOUR);

-- -----------------------------------------------------------------------------
-- mon_pipeline_step_runs: one row per run per step.
--   step_status  Completed / Completed with warnings / Failed (an error, or
--                started without completing) / Not run / Not deployed (the
--                step's procedure had never logged before this run)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_pipeline_step_runs
OPTIONS(description="One row per pipeline run per step (1 to 9): status, start, finish, duration, warnings and errors")
AS
WITH runs AS (
    SELECT run_batch_id, MIN(event_at) AS run_started_at
    FROM statement_competitor_data_warehouse.mon_pipeline_events
    WHERE run_batch_id IS NOT NULL
    GROUP BY run_batch_id
),
steps AS (
    SELECT * FROM UNNEST([
        STRUCT(1 AS step_no, 'Load Bronze' AS step_name, 'sp_load_bronze_products' AS procedure_name),
        STRUCT(2, 'Validate Bronze', 'sp_validate_bronze_products'),
        STRUCT(3, 'Check scrape health', 'sp_check_scrape_health'),
        STRUCT(4, 'Load Silver', 'sp_load_silver_products'),
        STRUCT(5, 'Validate Silver', 'sp_validate_silver_products'),
        STRUCT(6, 'Build star schema', 'sp_normalise_silver_products'),
        STRUCT(7, 'Record price history', 'sp_load_dim_price_history'),
        STRUCT(8, 'Reconcile', 'sp_reconciled_silver_products'),
        STRUCT(9, 'Refresh report tables', 'sp_refresh_report_tables')
    ])
),
-- First event ever logged by each step, to tell 'not deployed yet' from 'not run'.
deployed AS (
    SELECT step_no, MIN(event_at) AS first_logged_at
    FROM statement_competitor_data_warehouse.mon_pipeline_events
    GROUP BY step_no
),
agg AS (
    SELECT
        run_batch_id,
        step_no,
        MIN(IF(event_type = 'INFO_STAGE_START', event_at, NULL)) AS started_at,
        MAX(IF(event_type = 'INFO_STAGE_COMPLETE', event_at, NULL)) AS finished_at,
        COUNTIF(severity = 'Warning') AS warnings,
        COUNTIF(severity = 'Error') AS errors,
        ARRAY_AGG(IF(event_type = 'INFO_STAGE_COMPLETE', details, NULL) IGNORE NULLS ORDER BY event_at DESC LIMIT 1)[SAFE_OFFSET(0)] AS completion_details,
        ARRAY_AGG(IF(severity != 'Info', details, NULL) IGNORE NULLS ORDER BY event_at DESC LIMIT 1)[SAFE_OFFSET(0)] AS latest_issue
    FROM statement_competitor_data_warehouse.mon_pipeline_events
    WHERE run_batch_id IS NOT NULL
    GROUP BY run_batch_id, step_no
)
SELECT
    r.run_batch_id,
    r.run_started_at,
    s.step_no,
    s.step_name,
    s.procedure_name,
    CASE
        WHEN a.errors > 0 OR (a.started_at IS NOT NULL AND a.finished_at IS NULL) THEN 'Failed'
        WHEN a.started_at IS NULL AND (d.first_logged_at IS NULL OR d.first_logged_at > r.run_started_at) THEN 'Not deployed'
        WHEN a.started_at IS NULL THEN 'Not run'
        WHEN a.warnings > 0 THEN 'Completed with warnings'
        ELSE 'Completed'
    END AS step_status,
    a.started_at,
    a.finished_at,
    TIMESTAMP_DIFF(a.finished_at, a.started_at, SECOND) AS duration_seconds,
    COALESCE(a.warnings, 0) AS warnings,
    COALESCE(a.errors, 0) AS errors,
    a.completion_details,
    a.latest_issue
FROM runs r
CROSS JOIN steps s
LEFT JOIN agg a ON a.run_batch_id = r.run_batch_id AND a.step_no = s.step_no
LEFT JOIN deployed d ON d.step_no = s.step_no;

-- -----------------------------------------------------------------------------
-- mon_pipeline_runs: one row per run.
--   pipeline_status  Failed (a step failed) / Incomplete (a deployed step did
--                    not run) / Completed with warnings / Healthy
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_pipeline_runs
OPTIONS(description="One row per pipeline run: overall status, step counts, timings, scrape health and data volumes per layer")
AS
WITH steps AS (
    SELECT
        run_batch_id,
        MIN(run_started_at) AS run_started_at,
        MAX(finished_at) AS run_finished_at,
        COUNTIF(step_status IN ('Completed', 'Completed with warnings')) AS steps_completed,
        COUNTIF(step_status = 'Completed with warnings') AS steps_with_warnings,
        COUNTIF(step_status = 'Failed') AS steps_failed,
        COUNTIF(step_status = 'Not run') AS steps_not_run,
        COUNTIF(step_status != 'Not deployed') AS steps_deployed,
        STRING_AGG(IF(step_status = 'Failed', FORMAT('%d %s', step_no, step_name), NULL), ', ' ORDER BY step_no) AS failed_steps,
        ANY_VALUE(IF(step_no = 1, completion_details, NULL)) AS load_details,
        ANY_VALUE(IF(step_no = 4, completion_details, NULL)) AS silver_details,
        ANY_VALUE(IF(step_no = 7, completion_details, NULL)) AS history_details,
        SUM(IF(step_no = 8, warnings, 0)) AS reconciliation_issues
    FROM statement_competitor_data_warehouse.mon_pipeline_step_runs
    GROUP BY run_batch_id
),
source_files AS (
    SELECT run_batch_id, ANY_VALUE(REGEXP_EXTRACT(details, r'(gs://\S+\.csv)')) AS source_file
    FROM statement_competitor_data_warehouse.mon_pipeline_events
    WHERE step_no = 1 AND event_type = 'INFO_STAGE_START'
    GROUP BY run_batch_id
),
bronze_validity AS (
    SELECT batch_id, SUM(records_processed) AS bronze_rows, SUM(records_quarantined) AS bronze_quarantined
    FROM statement_competitor_data_warehouse.bronze_validity_log
    GROUP BY batch_id
),
-- Silver validation logs its own batch id, so attach it to the run by time.
silver_validity AS (
    SELECT
        s.run_batch_id,
        SUM(v.records_processed) AS silver_rows_validated,
        SUM(v.records_quarantined) AS silver_quarantined
    FROM statement_competitor_data_warehouse.silver_validity_log v
    JOIN steps s
      ON v.validation_timestamp >= s.run_started_at
     AND v.validation_timestamp <= TIMESTAMP_ADD(COALESCE(s.run_finished_at, s.run_started_at), INTERVAL 1 MINUTE)
    GROUP BY s.run_batch_id
)
SELECT
    s.run_batch_id,
    f.source_file,
    SAFE.PARSE_DATE('%Y-%m-%d', REGEXP_EXTRACT(f.source_file, r'(\d{4}-\d{2}-\d{2})\.csv$')) AS scrape_date,
    s.run_started_at,
    s.run_finished_at,
    ROUND(TIMESTAMP_DIFF(s.run_finished_at, s.run_started_at, SECOND) / 60, 1) AS pipeline_minutes,
    CASE
        WHEN s.steps_failed > 0 THEN 'Failed'
        WHEN s.steps_not_run > 0 THEN 'Incomplete'
        WHEN s.steps_with_warnings > 0 THEN 'Completed with warnings'
        ELSE 'Healthy'
    END AS pipeline_status,
    s.steps_deployed,
    s.steps_completed,
    s.steps_with_warnings,
    s.steps_failed,
    s.failed_steps,
    m.run_status AS scrape_status,
    m.shops,
    m.shops_healthy,
    m.shops_warning,
    m.shops_failed,
    m.failed_shops,
    m.duration_minutes AS scrape_minutes,
    m.http_errors,
    m.products_in_csv,
    b.bronze_rows,
    b.bronze_quarantined,
    ROUND(SAFE_DIVIDE(b.bronze_quarantined, b.bronze_rows) * 100, 2) AS bronze_quarantine_pct,
    SAFE_CAST(REGEXP_EXTRACT(s.silver_details, r'inserted or changed: (\d+)') AS INT64) AS silver_rows_changed,
    sv.silver_rows_validated,
    sv.silver_quarantined,
    SAFE_CAST(REGEXP_EXTRACT(s.history_details, r'Records Expired: (\d+)') AS INT64) AS price_changes,
    SAFE_CAST(REGEXP_EXTRACT(s.history_details, r'Records Inserted: (\d+)') AS INT64) AS history_rows_inserted,
    s.reconciliation_issues,
    DATE_DIFF(DATE(s.run_started_at), DATE(LAG(s.run_started_at) OVER (ORDER BY s.run_started_at)), DAY) AS days_since_previous_run,
    s.run_started_at = MAX(s.run_started_at) OVER () AS is_latest_run
FROM steps s
LEFT JOIN source_files f USING (run_batch_id)
LEFT JOIN statement_competitor_data_warehouse.mon_scrape_runs m ON m.batch_id = s.run_batch_id
LEFT JOIN bronze_validity b ON b.batch_id = s.run_batch_id
LEFT JOIN silver_validity sv USING (run_batch_id);

-- -----------------------------------------------------------------------------
-- mon_shop_freshness: one row per shop.
--   freshness  Fresh     latest scrape not FAILED
--              Stale     1 failed run in a row
--              Critical  2 or more failed runs in a row, or never healthy
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_shop_freshness
OPTIONS(description="One row per shop: latest scrape result, last good scrape, days since, failed runs in a row and latest error")
AS
WITH shop_runs AS (
    SELECT
        *,
        -- Runs since the last good scrape (0 when the latest run was good).
        COUNTIF(health_status != 'FAILED') OVER (
            PARTITION BY shop_name ORDER BY loaded_at DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS good_runs_since
    FROM statement_competitor_data_warehouse.mon_scrape_shop_runs
)
SELECT
    shop_name,
    ARRAY_AGG(STRUCT(loaded_at AS latest_scrape_at, health_status AS latest_status, issues AS latest_issues,
                     error_message AS latest_error, products_in_csv AS latest_products, baseline_count,
                     http_errors AS latest_http_errors)
              ORDER BY loaded_at DESC LIMIT 1)[OFFSET(0)].*,
    MAX(IF(health_status != 'FAILED', loaded_at, NULL)) AS last_good_scrape_at,
    DATE_DIFF(CURRENT_DATE('Africa/Johannesburg'),
              DATE(MAX(IF(health_status != 'FAILED', loaded_at, NULL)), 'Africa/Johannesburg'), DAY) AS days_since_good_scrape,
    COUNTIF(good_runs_since = 0) AS failed_runs_in_a_row,
    COUNT(*) AS runs,
    COUNTIF(health_status = 'FAILED') AS failed_runs,
    ROUND(SAFE_DIVIDE(COUNTIF(health_status = 'FAILED'), COUNT(*)) * 100, 1) AS failure_rate_pct,
    CASE
        WHEN MAX(IF(health_status != 'FAILED', loaded_at, NULL)) IS NULL OR COUNTIF(good_runs_since = 0) >= 2 THEN 'Critical'
        WHEN COUNTIF(good_runs_since = 0) = 1 THEN 'Stale'
        ELSE 'Fresh'
    END AS freshness
FROM shop_runs
GROUP BY shop_name;

-- -----------------------------------------------------------------------------
-- mon_warehouse_tables: row count and size per table, grouped by layer.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_warehouse_tables
OPTIONS(description="Row count, size and last change per warehouse table, with its layer")
AS
SELECT
    table_id AS table_name,
    CASE
        WHEN table_id LIKE 'bronze\\_%' THEN 'Bronze'
        WHEN REGEXP_CONTAINS(table_id, r'^(silver|dim|fact)_') THEN 'Silver'
        WHEN table_id LIKE 'ref\\_%' THEN 'Reference'
        WHEN table_id LIKE 'rpt\\_%' THEN 'Report'
        WHEN REGEXP_CONTAINS(table_id, r'^(mon|ops)_') THEN 'Operations'
        ELSE 'Other'
    END AS layer,
    row_count,
    ROUND(size_bytes / POW(1024, 2), 2) AS size_mb,
    TIMESTAMP_MILLIS(last_modified_time) AS last_modified_at
FROM statement_competitor_data_warehouse.__TABLES__
WHERE type = 1;

-- -----------------------------------------------------------------------------
-- mon_query_costs: BigQuery query jobs per day over the last 90 days.
--   est_cost_usd is the on-demand list price ($6.25 per TiB) before the free
--   1 TiB a month, so the real bill is lower (usually zero).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_query_costs
OPTIONS(description="BigQuery query jobs per day and source over 90 days: jobs, failures, GiB billed, cost at list price before the free tier")
AS
SELECT
    DATE(creation_time, 'Africa/Johannesburg') AS job_date,
    CASE
        WHEN user_email LIKE '%gserviceaccount.com' THEN 'Automation'
        WHEN EXISTS (SELECT 1 FROM UNNEST(labels) l WHERE l.key = 'goog-mcp-server') THEN 'Claude'
        ELSE 'Interactive and Data Studio'
    END AS source,
    COUNT(*) AS jobs,
    COUNTIF(error_result IS NOT NULL) AS failed_jobs,
    ROUND(SUM(total_bytes_billed) / POW(1024, 3), 3) AS gib_billed,
    ROUND(SUM(total_bytes_billed) / POW(1024, 4) * 6.25, 4) AS est_cost_usd
FROM `region-us-east1`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  AND job_type = 'QUERY'
  AND statement_type != 'SCRIPT'
GROUP BY job_date, source;


/*
===============================================================================
Tests (run manually)
===============================================================================
-- All six views exist (expect 6 rows, table_type = VIEW).
SELECT table_name, table_type
FROM `statement_competitor_data_warehouse.INFORMATION_SCHEMA.TABLES`
WHERE table_name IN ('mon_pipeline_events', 'mon_pipeline_step_runs', 'mon_pipeline_runs',
                     'mon_shop_freshness', 'mon_warehouse_tables', 'mon_query_costs')
ORDER BY table_name;

-- Every run has 9 step rows (expect no rows).
SELECT run_batch_id, COUNT(*) AS steps
FROM statement_competitor_data_warehouse.mon_pipeline_step_runs
GROUP BY run_batch_id
HAVING COUNT(*) != 9;

-- Every event is mapped to a step (expect 0).
SELECT COUNT(*) AS unmapped_events
FROM statement_competitor_data_warehouse.mon_pipeline_events
WHERE step_no IS NULL;

-- Runs, newest first.
SELECT run_started_at, pipeline_status, steps_completed, steps_deployed, failed_steps, scrape_status,
       shops_healthy, shops_failed, products_in_csv, silver_rows_changed, price_changes,
       reconciliation_issues, pipeline_minutes, scrape_minutes, days_since_previous_run
FROM statement_competitor_data_warehouse.mon_pipeline_runs
ORDER BY run_started_at DESC;

-- Shops by freshness, worst first.
SELECT shop_name, freshness, latest_status, last_good_scrape_at, days_since_good_scrape,
       failed_runs_in_a_row, failure_rate_pct, latest_error
FROM statement_competitor_data_warehouse.mon_shop_freshness
ORDER BY failed_runs_in_a_row DESC, shop_name;

-- Spend this month at list price (the free tier covers the first 1 TiB).
SELECT SUM(gib_billed) AS gib_billed, SUM(est_cost_usd) AS est_cost_usd
FROM statement_competitor_data_warehouse.mon_query_costs
WHERE job_date >= DATE_TRUNC(CURRENT_DATE('Africa/Johannesburg'), MONTH);
*/
