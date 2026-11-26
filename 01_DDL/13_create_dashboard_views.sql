/*
===============================================================================
Script   : 13_create_dashboard_views.sql
Layer    : Monitoring
Purpose  : The queries behind the Pipeline Vitals dashboard, one view per
           dashboard section (mon_dash_<dataset id>), and the table that
           freezes them once a week:
             mon_dash_vitals     header and vital tiles (1 row)
             mon_dash_problems   This week's problems
             mon_dash_steps      steps x last 12 runs
             mon_dash_shopruns   shops x last 12 runs
             mon_dash_runs       one row per run (trends)
             mon_dash_shops      shop freshness
             mon_dash_events     40 most recent warnings and errors
             mon_dash_costs      BigQuery use per week and source
             mon_dash_layers     warehouse size per layer
             ops_vitals_snapshots  frozen copies of every mon_dash_ view,
                                   one set per pipeline run
           The live dashboard (the template) reads the views. Each weekly
           report reads the snapshot of its own run, so its numbers never
           change. sp_snapshot_pipeline_vitals (02_Stored_Procedures/12)
           writes the snapshots.
When     : Initial setup, after 12_create_pipeline_monitoring_views.sql.
           Re-run after any change to this file. Safe to re-run.
Rules    : Every mon_dash_ view has a row_order column: the order the
           dashboard shows its rows in. The snapshot procedure freezes every
           view named mon_dash_%, so a new dashboard section only needs a new
           view here, named after its dataset id.
Warning  : Views hold no data. Never edit ops_vitals_snapshots by hand: it is
           the only record of past weeks.
===============================================================================
*/

-- -----------------------------------------------------------------------------
-- mon_dash_vitals
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_dash_vitals
OPTIONS(description="Pipeline Vitals dashboard, header and tiles: one row of headline figures for the latest run")
AS
WITH r AS (
  SELECT * FROM statement_competitor_data_warehouse.mon_pipeline_runs WHERE is_latest_run
),
s AS (
  SELECT COUNT(*) AS shops_tracked,
         COUNTIF(freshness = 'Fresh') AS shops_fresh,
         COUNTIF(freshness = 'Stale') AS shops_stale,
         COUNTIF(freshness = 'Critical') AS shops_critical
  FROM statement_competitor_data_warehouse.mon_shop_freshness
),
c AS (
  SELECT ROUND(SUM(gib_billed), 2) AS gib_this_month, ROUND(SUM(est_cost_usd), 2) AS list_cost_usd_this_month
  FROM statement_competitor_data_warehouse.mon_query_costs
  WHERE job_date >= DATE_TRUNC(CURRENT_DATE('Africa/Johannesburg'), MONTH)
),
p AS (
  SELECT COUNTIF(is_active) AS active_listings FROM statement_competitor_data_warehouse.rpt_market_products
),
v AS (
  SELECT r.*, s.*, c.*, p.*,
         DATE_DIFF(CURRENT_DATE('Africa/Johannesburg'), DATE(r.run_started_at, 'Africa/Johannesburg'), DAY) AS days_since_last_run,
         -- Next Thursday (today on a Thursday): the scraper uploads at 19:00 and the pipeline starts.
         DATE_ADD(CURRENT_DATE('Africa/Johannesburg'),
                  INTERVAL MOD(12 - EXTRACT(DAYOFWEEK FROM CURRENT_DATE('Africa/Johannesburg')), 7) DAY) AS next_run_date
  FROM r, s, c, p
)
SELECT
  CASE
    WHEN pipeline_status IN ('Failed', 'Incomplete') OR shops_critical > 0 OR days_since_last_run > 8 THEN 'Needs attention'
    WHEN pipeline_status IN ('Recovered', 'Completed with warnings') OR scrape_status != 'HEALTHY' OR shops_stale > 0 THEN 'Watch'
    ELSE 'Healthy'
  END AS overall_health,
  pipeline_status,
  INITCAP(scrape_status) AS scrape_status,
  FORMAT_TIMESTAMP('%a %d %b %Y, %H:%M', run_started_at, 'Africa/Johannesburg') AS last_run_at,
  FORMAT_DATE('%d %b %Y', scrape_date) AS last_scrape_date,
  days_since_last_run,
  FORMAT_DATE('%a %d %b', next_run_date) AS next_run_date,
  steps_completed,
  steps_deployed,
  steps_with_warnings,
  steps_failed,
  shops_healthy,
  shops,
  shops_failed,
  shops_tracked,
  shops_fresh,
  shops_stale,
  shops_critical,
  products_in_csv,
  active_listings,
  silver_rows_changed,
  price_changes,
  COALESCE(bronze_quarantined, 0) + COALESCE(silver_quarantined, 0) AS rows_quarantined,
  reconciliation_issues,
  pipeline_minutes,
  scrape_minutes,
  http_errors,
  gib_this_month,
  list_cost_usd_this_month,
  1 AS row_order
FROM v;

-- -----------------------------------------------------------------------------
-- mon_dash_problems
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_dash_problems
OPTIONS(description="Pipeline Vitals dashboard, This week's problems: one row per problem in the latest run, most urgent first")
AS
WITH lr AS (
  SELECT * FROM statement_competitor_data_warehouse.mon_pipeline_runs WHERE is_latest_run
),
prev AS (
  SELECT * FROM statement_competitor_data_warehouse.mon_pipeline_runs
  QUALIFY ROW_NUMBER() OVER (ORDER BY run_started_at DESC) = 2
),
age AS (
  SELECT DATE_DIFF(CURRENT_DATE('Africa/Johannesburg'), DATE(run_started_at, 'Africa/Johannesburg'), DAY) AS days,
         FORMAT_TIMESTAMP('%a %d %b', run_started_at, 'Africa/Johannesburg') AS run_label
  FROM lr
),
shop_now AS (
  SELECT
    sr.shop_name, sr.health_status, sr.issues, sr.baseline_count, sr.duration_minutes, sr.retries,
    f.failed_runs_in_a_row,
    CASE COALESCE(REGEXP_EXTRACT(sr.error_message, r'HTTP (\d{3})'), REGEXP_EXTRACT(sr.error_message, r'(\d{3}) Client Error'))
      WHEN '429' THEN 'rate limited (HTTP 429)'
      WHEN '403' THEN 'blocked (HTTP 403)'
      WHEN '404' THEN 'not found (HTTP 404)'
      ELSE COALESCE(sr.issues, 'failed')
    END AS cause,
    COALESCE(REGEXP_EXTRACT(sr.error_message, r'HTTP (\d{3})'), REGEXP_EXTRACT(sr.error_message, r'(\d{3}) Client Error')) AS http_code
  FROM statement_competitor_data_warehouse.mon_scrape_shop_runs sr
  JOIN lr ON sr.batch_id = lr.run_batch_id
  LEFT JOIN statement_competitor_data_warehouse.mon_shop_freshness f USING (shop_name)
),
slowest AS (
  SELECT FORMAT('Slowest shops: %s. %d retries in total.',
                STRING_AGG(FORMAT('%s %.1f min', shop_name, duration_minutes), ', ' ORDER BY duration_minutes DESC LIMIT 3),
                SUM(COALESCE(retries, 0))) AS note
  FROM shop_now
),
problems AS (
  -- Pipeline overdue.
  SELECT 1 AS priority, 'Schedule' AS area,
         FORMAT('No pipeline run for %d days', age.days) AS headline,
         FORMAT("The last run was %s. Runs are due every Thursday at about 19:00, when the scraper uploads the week's CSV.", age.run_label) AS detail,
         "Check the week's status file and log in 06_Datasets on the Mac, then the incoming/ folder in the bucket: the pipeline only starts when a CSV is uploaded." AS action,
         'vitals' AS section,
         1000000 AS impact
  FROM age WHERE age.days > 8

  UNION ALL
  -- Warehouse steps that failed or did not run.
  SELECT 1, 'Warehouse',
         FORMAT('Step %d, %s: %s', s.step_no, s.step_name, LOWER(s.step_status)),
         COALESCE(LEFT(s.latest_issue, 300), 'The step started but never logged completion.'),
         "Read the step's log table, fix the cause, then run the remaining steps by hand (Manual, section 5).",
         'flow',
         1000000 - s.step_no
  FROM statement_competitor_data_warehouse.mon_pipeline_step_runs s
  JOIN lr USING (run_batch_id)
  WHERE s.step_status IN ('Failed', 'Not run')

  UNION ALL
  -- Steps that failed in the run and were re-run by hand before the next run.
  SELECT 3, 'Warehouse',
         FORMAT('Step %d, %s: failed, recovered by hand', s.step_no, s.step_name),
         FORMAT('Re-run on %s (%s). Original error: %s',
                FORMAT_TIMESTAMP('%a %d %b, %H:%M', s.recovered_at, 'Africa/Johannesburg'),
                lr.recovered_steps,
                COALESCE(LEFT(s.latest_issue, 240), 'none logged')),
         'No action if the error was a one-off BigQuery error (it says Retrying may solve the problem). If it repeats next run, fix the cause in the step.',
         'flow',
         1000 - s.step_no
  FROM statement_competitor_data_warehouse.mon_pipeline_step_runs s
  JOIN lr USING (run_batch_id)
  WHERE s.step_status = 'Recovered' AND s.original_status = 'Failed'

  UNION ALL
  -- Shops that failed to scrape, grouped by cause.
  SELECT IF(MAX(failed_runs_in_a_row) >= 2, 1, 2), 'Scraper',
         FORMAT('%d %s %s', COUNT(*), IF(COUNT(*) = 1, 'shop', 'shops'), cause),
         FORMAT('%s. About %d products not loaded; their stock is held at the last good scrape.%s',
                STRING_AGG(shop_name, ', ' ORDER BY shop_name), SUM(COALESCE(baseline_count, 0)),
                IF(MAX(failed_runs_in_a_row) >= 2, ' Failed two runs or more in a row.', ' First failure in a row.')),
         CASE ANY_VALUE(http_code)
           WHEN '429' THEN 'Shopify limits requests per IP address across all its shops. Check the pauses and second attempts in the scrape log, and record the failure in scraper_error_log.md. If the same big shops keep failing, scrape them on a separate day.'
           WHEN '403' THEN 'The shop refused the scraper. Confirm the scraper still sends its honest User-Agent (common.py) and that products.json is still public, then record it in scraper_error_log.md. Never switch to a browser User-Agent: Shopify blocks that.'
           ELSE 'Read the error in the shop freshness table and the scrape log.'
         END,
         'shops',
         SUM(COALESCE(baseline_count, 0))
  FROM shop_now
  WHERE health_status = 'FAILED'
  GROUP BY cause

  UNION ALL
  -- Shops scraped with warnings.
  SELECT 3, 'Scraper',
         FORMAT('%d %s scraped with warnings', COUNT(*), IF(COUNT(*) = 1, 'shop', 'shops')),
         STRING_AGG(FORMAT('%s (%s)', shop_name, COALESCE(issues, 'warning')), ', ' ORDER BY shop_name),
         'Compare their product counts with the baseline in the scrape history: a partial scrape can look like sales.',
         'shops',
         COUNT(*)
  FROM shop_now
  WHERE health_status = 'WARNING'
  HAVING COUNT(*) > 0

  UNION ALL
  -- Product volume drop.
  SELECT 2, 'Volume',
         FORMAT('Products loaded fell %d%% (%d to %d)',
                CAST(ROUND((1 - SAFE_DIVIDE(lr.products_in_csv, prev.products_in_csv)) * 100) AS INT64),
                prev.products_in_csv, lr.products_in_csv),
         IF(lr.shops_failed > 0,
            FORMAT('%d of %d shops failed to scrape, which accounts for most of the drop.', lr.shops_failed, lr.shops),
            'No shop failed, so a shop may have scraped only part of its stock.'),
         IF(lr.shops_failed > 0,
            'Fix the scraper problems above. Volume returns once those shops scrape again.',
            'Compare each shop with its baseline in the scrape history grid.'),
         'trends',
         prev.products_in_csv - lr.products_in_csv
  FROM lr, prev
  WHERE lr.products_in_csv < prev.products_in_csv * 0.8

  UNION ALL
  -- Scrape getting slower.
  SELECT 3, 'Performance',
         FORMAT('Scrape took %.1f min, up %d%% on the previous run', lr.scrape_minutes,
                CAST(ROUND((SAFE_DIVIDE(lr.scrape_minutes, prev.scrape_minutes) - 1) * 100) AS INT64)),
         slowest.note,
         "Retries on failing shops add waiting time, so fixing the rate limits shortens the run. Then check the slowest shops' page counts and delays.",
         'trends',
         CAST(lr.scrape_minutes - prev.scrape_minutes AS INT64)
  FROM lr, prev, slowest
  WHERE lr.scrape_minutes > prev.scrape_minutes * 1.25 AND lr.scrape_minutes - prev.scrape_minutes >= 5

  UNION ALL
  -- Quarantined rows.
  SELECT 2, 'Data quality',
         FORMAT('%d rows quarantined', COALESCE(lr.bronze_quarantined, 0) + COALESCE(lr.silver_quarantined, 0)),
         FORMAT('Bronze %d, Silver %d.', COALESCE(lr.bronze_quarantined, 0), COALESCE(lr.silver_quarantined, 0)),
         'Read the reasons in bronze_quarantine_bad_records and silver_quarantine_bad_records for this batch (Manual, section 12.1).',
         'vitals',
         COALESCE(lr.bronze_quarantined, 0) + COALESCE(lr.silver_quarantined, 0)
  FROM lr
  WHERE COALESCE(lr.bronze_quarantined, 0) + COALESCE(lr.silver_quarantined, 0) > 0

  UNION ALL
  -- Reconciliation findings other than failed scrapes (those are listed under Scraper).
  SELECT 2, 'Data quality',
         FORMAT('Reconciliation finding: %s', e.event_type),
         LEFT(ANY_VALUE(e.details), 300),
         'See the Tests block of 08_sp_reconciled_silver_products.sql and Manual, section 14.',
         'issues',
         COUNT(*)
  FROM statement_competitor_data_warehouse.mon_pipeline_events e
  JOIN lr USING (run_batch_id)
  WHERE e.step_no = 8 AND e.severity = 'Warning' AND e.event_type != 'SCRAPE_FAILURE'
  GROUP BY e.event_type

  UNION ALL
  -- Warnings from warehouse steps other than the scrape checks (steps 3 and 8).
  SELECT 3, 'Warehouse',
         FORMAT('Step %d, %s: %d %s', s.step_no, s.step_name, s.warnings, IF(s.warnings = 1, 'warning', 'warnings')),
         LEFT(s.latest_issue, 300),
         'Read the warning under Warnings and errors.',
         'issues',
         s.warnings
  FROM statement_competitor_data_warehouse.mon_pipeline_step_runs s
  JOIN lr USING (run_batch_id)
  WHERE s.warnings > 0 AND s.step_no NOT IN (3, 8) AND s.step_status NOT IN ('Failed', 'Recovered')
)
SELECT
  FORMAT('%d-%02d', priority, ROW_NUMBER() OVER (ORDER BY priority, CASE area WHEN 'Schedule' THEN 1 WHEN 'Warehouse' THEN 2 WHEN 'Scraper' THEN 3 WHEN 'Data quality' THEN 4 WHEN 'Volume' THEN 5 ELSE 6 END, impact DESC, headline)) AS problem_id,
  priority,
  CASE priority WHEN 1 THEN 'Critical' WHEN 2 THEN 'High' ELSE 'Medium' END AS severity,
  area,
  headline,
  detail,
  action,
  section,
  impact,
  ROW_NUMBER() OVER (ORDER BY priority, CASE area WHEN 'Schedule' THEN 1 WHEN 'Warehouse' THEN 2 WHEN 'Scraper' THEN 3 WHEN 'Data quality' THEN 4 WHEN 'Volume' THEN 5 ELSE 6 END, impact DESC, headline) AS row_order
FROM problems;

-- -----------------------------------------------------------------------------
-- mon_dash_steps
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_dash_steps
OPTIONS(description="Pipeline Vitals dashboard, steps: status and duration of each step in the last 12 runs")
AS
WITH runs AS (
  SELECT run_batch_id, run_started_at, is_latest_run
  FROM statement_competitor_data_warehouse.mon_pipeline_runs
  QUALIFY ROW_NUMBER() OVER (ORDER BY run_started_at DESC) <= 12
)
SELECT
  s.run_batch_id,
  FORMAT_DATE('%Y-%m-%d', DATE(r.run_started_at, 'Africa/Johannesburg')) AS run_date,
  r.is_latest_run,
  s.step_no,
  s.step_name,
  s.step_status,
  s.duration_seconds,
  s.warnings,
  s.errors,
  s.latest_issue,
  ROW_NUMBER() OVER (ORDER BY r.run_started_at, s.step_no) AS row_order
FROM statement_competitor_data_warehouse.mon_pipeline_step_runs s
JOIN runs r USING (run_batch_id);

-- -----------------------------------------------------------------------------
-- mon_dash_shopruns
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_dash_shopruns
OPTIONS(description="Pipeline Vitals dashboard, shop grid: each shop's scrape result in the last 12 runs")
AS
WITH runs AS (
  SELECT run_batch_id, run_started_at
  FROM statement_competitor_data_warehouse.mon_pipeline_runs
  QUALIFY ROW_NUMBER() OVER (ORDER BY run_started_at DESC) <= 12
)
SELECT
  sr.shop_name,
  FORMAT_DATE('%Y-%m-%d', DATE(r.run_started_at, 'Africa/Johannesburg')) AS run_date,
  sr.health_status,
  sr.issues,
  sr.products_in_csv,
  sr.baseline_count,
  sr.pct_of_baseline,
  sr.duration_minutes,
  sr.http_errors,
  sr.retries,
  ROW_NUMBER() OVER (ORDER BY sr.shop_name, r.run_started_at) AS row_order
FROM statement_competitor_data_warehouse.mon_scrape_shop_runs sr
JOIN runs r ON r.run_batch_id = sr.batch_id;

-- -----------------------------------------------------------------------------
-- mon_dash_runs
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_dash_runs
OPTIONS(description="Pipeline Vitals dashboard, trends: one row per run with volumes and timings")
AS
SELECT
  run_batch_id,
  FORMAT_DATE('%Y-%m-%d', DATE(run_started_at, 'Africa/Johannesburg')) AS run_date,
  FORMAT_DATE('%Y-%m-%d', scrape_date) AS scrape_date,
  pipeline_status,
  INITCAP(scrape_status) AS scrape_status,
  shops_healthy,
  shops_warning,
  shops_failed,
  products_in_csv,
  silver_rows_changed,
  price_changes,
  COALESCE(bronze_quarantined, 0) + COALESCE(silver_quarantined, 0) AS rows_quarantined,
  reconciliation_issues,
  pipeline_minutes,
  scrape_minutes,
  http_errors,
  ROW_NUMBER() OVER (ORDER BY run_started_at) AS row_order
FROM statement_competitor_data_warehouse.mon_pipeline_runs;

-- -----------------------------------------------------------------------------
-- mon_dash_shops
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_dash_shops
OPTIONS(description="Pipeline Vitals dashboard, shop freshness: one row per shop")
AS
SELECT
  shop_name,
  freshness,
  INITCAP(latest_status) AS latest_status,
  FORMAT_TIMESTAMP('%d %b %Y', last_good_scrape_at, 'Africa/Johannesburg') AS last_good_scrape,
  days_since_good_scrape,
  failed_runs_in_a_row,
  failed_runs,
  runs,
  latest_products,
  baseline_count,
  CASE COALESCE(REGEXP_EXTRACT(latest_error, r'HTTP (\d{3})'), REGEXP_EXTRACT(latest_error, r'(\d{3}) Client Error'))
    WHEN '429' THEN 'HTTP 429: rate limited'
    WHEN '403' THEN 'HTTP 403: blocked'
    WHEN '404' THEN 'HTTP 404: not found'
    ELSE LEFT(latest_error, 60)
  END AS latest_error_short,
  latest_error,
  ROW_NUMBER() OVER (ORDER BY CASE freshness WHEN 'Critical' THEN 0 WHEN 'Stale' THEN 1 ELSE 2 END, shop_name) AS row_order
FROM statement_competitor_data_warehouse.mon_shop_freshness;

-- -----------------------------------------------------------------------------
-- mon_dash_events
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_dash_events
OPTIONS(description="Pipeline Vitals dashboard, warnings and errors: the 40 most recent non-routine log events")
AS
SELECT
  FORMAT('%s-%03d', FORMAT_TIMESTAMP('%Y%m%d%H%M%S', event_at), ROW_NUMBER() OVER (ORDER BY event_at DESC, details)) AS event_key,
  FORMAT_TIMESTAMP('%d %b %Y, %H:%M', event_at, 'Africa/Johannesburg') AS logged_at,
  step_no,
  procedure_name,
  severity,
  event_type,
  details,
  ROW_NUMBER() OVER (ORDER BY event_at DESC, details) AS row_order
FROM statement_competitor_data_warehouse.mon_pipeline_events
WHERE severity != 'Info'
QUALIFY row_order <= 40;

-- -----------------------------------------------------------------------------
-- mon_dash_costs
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_dash_costs
OPTIONS(description="Pipeline Vitals dashboard, cost: BigQuery GiB and list-price cost per week and source over 90 days")
AS
WITH weekly AS (
  SELECT
    FORMAT_DATE('%Y-%m-%d', DATE_TRUNC(job_date, WEEK(MONDAY))) AS week_start,
    source,
    SUM(jobs) AS jobs,
    SUM(failed_jobs) AS failed_jobs,
    ROUND(SUM(gib_billed), 3) AS gib_billed,
    ROUND(SUM(est_cost_usd), 4) AS list_cost_usd
  FROM statement_competitor_data_warehouse.mon_query_costs
  GROUP BY week_start, source
)
SELECT *, ROW_NUMBER() OVER (ORDER BY week_start, source) AS row_order
FROM weekly;

-- -----------------------------------------------------------------------------
-- mon_dash_layers
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.mon_dash_layers
OPTIONS(description="Pipeline Vitals dashboard, warehouse: tables, rows and size per layer")
AS
WITH layers AS (
  SELECT
    layer,
    COUNT(*) AS tables,
    SUM(row_count) AS row_count,
    ROUND(SUM(size_mb), 2) AS size_mb,
    FORMAT_TIMESTAMP('%d %b %Y, %H:%M', MAX(last_modified_at), 'Africa/Johannesburg') AS last_change
  FROM statement_competitor_data_warehouse.mon_warehouse_tables
  GROUP BY layer
)
SELECT *, ROW_NUMBER() OVER (ORDER BY CASE layer WHEN 'Bronze' THEN 1 WHEN 'Silver' THEN 2 WHEN 'Reference' THEN 3 WHEN 'Report' THEN 4 WHEN 'Operations' THEN 5 ELSE 6 END) AS row_order
FROM layers;

-- -----------------------------------------------------------------------------
-- ops_vitals_snapshots: frozen rows of every mon_dash_ view, per pipeline run
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS statement_competitor_data_warehouse.ops_vitals_snapshots (
    run_batch_id STRING NOT NULL OPTIONS(description="Bronze batch of the pipeline run the snapshot records"),
    dataset STRING NOT NULL OPTIONS(description="Dashboard dataset id: the view name without mon_dash_"),
    taken_at TIMESTAMP NOT NULL OPTIONS(description="When the snapshot was taken"),
    row_count INT64 OPTIONS(description="Rows in the view at that moment"),
    rows_json STRING OPTIONS(description="The view's rows as a JSON array of objects, in row_order")
)
PARTITION BY DATE(taken_at)
CLUSTER BY run_batch_id, dataset
OPTIONS(description="Frozen copies of the Pipeline Vitals dashboard views, one set per run. Written by sp_snapshot_pipeline_vitals; read by the weekly reports.");


/*
===============================================================================
Tests (run manually)
===============================================================================
-- All nine dashboard views exist (expect 9).
SELECT COUNT(*) AS dashboard_views
FROM `statement_competitor_data_warehouse.INFORMATION_SCHEMA.VIEWS`
WHERE table_name LIKE 'mon\\_dash\\_%';

-- Every view has a row_order column (expect no rows).
SELECT v.table_name
FROM `statement_competitor_data_warehouse.INFORMATION_SCHEMA.VIEWS` v
LEFT JOIN `statement_competitor_data_warehouse.INFORMATION_SCHEMA.COLUMNS` c
  ON c.table_name = v.table_name AND c.column_name = 'row_order'
WHERE v.table_name LIKE 'mon\\_dash\\_%' AND c.column_name IS NULL;

-- Rows per view right now.
SELECT 'vitals' AS dataset, COUNT(*) AS row_count FROM statement_competitor_data_warehouse.mon_dash_vitals UNION ALL
SELECT 'problems', COUNT(*) FROM statement_competitor_data_warehouse.mon_dash_problems UNION ALL
SELECT 'steps', COUNT(*) FROM statement_competitor_data_warehouse.mon_dash_steps UNION ALL
SELECT 'shopruns', COUNT(*) FROM statement_competitor_data_warehouse.mon_dash_shopruns UNION ALL
SELECT 'runs', COUNT(*) FROM statement_competitor_data_warehouse.mon_dash_runs UNION ALL
SELECT 'shops', COUNT(*) FROM statement_competitor_data_warehouse.mon_dash_shops UNION ALL
SELECT 'events', COUNT(*) FROM statement_competitor_data_warehouse.mon_dash_events UNION ALL
SELECT 'costs', COUNT(*) FROM statement_competitor_data_warehouse.mon_dash_costs UNION ALL
SELECT 'layers', COUNT(*) FROM statement_competitor_data_warehouse.mon_dash_layers;

-- Snapshots taken, newest first.
SELECT run_batch_id, MIN(taken_at) AS taken_at, COUNT(*) AS datasets, SUM(row_count) AS row_count
FROM statement_competitor_data_warehouse.ops_vitals_snapshots
GROUP BY run_batch_id
ORDER BY taken_at DESC;
*/
