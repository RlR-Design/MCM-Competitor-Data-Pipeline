/*
===============================================================================
Script   : 11_create_report_tables.sql
Layer    : Report
Purpose  : Creates rpt_refresh_error_logs, the log of sp_refresh_report_tables
           (pipeline step 9). The report tables themselves (rpt_*) are
           snapshots of Gold views, created and replaced by that procedure:
             rpt_market_products        gold_market_products
             rpt_client_price_position  gold_client_price_position
             rpt_value_drivers          gold_value_drivers
             rpt_sales                  gold_sales
           Data Studio reads only rpt_* tables: one fast, cheap table per
           chart instead of the full stack of Gold views on every load.
When     : Initial setup, after 10_create_gold_client_views.sql and before
           deploying 02_Stored_Procedures/11. Safe to re-run.
Warning  : Do not edit rpt_* tables by hand: step 9 replaces them on every
           run. To change one, change its Gold view and CALL
           sp_refresh_report_tables().
===============================================================================
*/

-- -----------------------------------------------------------------------------
-- rpt_refresh_error_logs: start, completion and error events of step 9
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS statement_competitor_data_warehouse.rpt_refresh_error_logs (
    log_id STRING OPTIONS(description="Unique identifier for the log entry (UUID)"),
    execution_id STRING OPTIONS(description="Pipeline execution identifier linking to the stored procedure run"),
    batch_id STRING OPTIONS(description="Batch identifier of the refresh run (BATCH_RPT_YYYYMMDD_HHMMSS)"),
    error_timestamp TIMESTAMP OPTIONS(description="Timestamp of the event"),
    procedure_name STRING OPTIONS(description="Name of the procedure logging the event"),
    error_type STRING OPTIONS(description="Event type (INFO_STAGE_START, INFO_STAGE_COMPLETE, REPORT_REFRESH_FAILURE)"),
    error_details STRING OPTIONS(description="Detailed message, including row counts per report table")
)
PARTITION BY DATE(error_timestamp);


/*
===============================================================================
Tests (run manually)
===============================================================================
-- Log table exists (expect one row).
SELECT table_name, table_type
FROM `statement_competitor_data_warehouse.INFORMATION_SCHEMA.TABLES`
WHERE table_name = 'rpt_refresh_error_logs';

-- Report tables and when they were last refreshed (expect four rows after step 9 has run).
SELECT table_id, row_count, TIMESTAMP_MILLIS(last_modified_time) AS last_refreshed
FROM `statement_competitor_data_warehouse.__TABLES__`
WHERE table_id LIKE 'rpt\\_%' AND table_id != 'rpt_refresh_error_logs'
ORDER BY table_id;
*/
