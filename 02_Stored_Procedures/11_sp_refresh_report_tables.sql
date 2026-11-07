/*
===============================================================================
Script   : 11_sp_refresh_report_tables.sql
Layer    : Report
Purpose  : Rebuilds the report tables Data Studio reads, one snapshot per
           Gold view, each with a refreshed_at column:
             rpt_market_products        from gold_market_products
             rpt_client_price_position  from gold_client_price_position
             rpt_value_drivers          from gold_value_drivers
             rpt_sales                  from gold_sales
           Data only changes once a week, so a snapshot loses nothing and
           makes each chart a single small table read.
When     : Deploy at setup and after any change. Runs as step 9 of
           sp_run_pipeline. CALL it manually after changing a Gold view.
Requires : 01_DDL/11 deployed; steps 1 to 8 completed.
Logs     : rpt_refresh_error_logs
Warning  : Replaces every rpt_* table on each run. Never edit them by hand.
===============================================================================
*/

CREATE OR REPLACE PROCEDURE statement_competitor_data_warehouse.sp_refresh_report_tables()
OPTIONS(strict_mode=false)
BEGIN
    DECLARE v_execution_id STRING;
    DECLARE v_batch_id STRING;
    DECLARE v_error_msg STRING;
    DECLARE v_summary STRING;

    -- Initialise run identifiers.
    SET v_execution_id = GENERATE_UUID();
    SET v_batch_id = FORMAT_TIMESTAMP('BATCH_RPT_%Y%m%d_%H%M%S', CURRENT_TIMESTAMP());

    BEGIN
        -- Log start.
        INSERT INTO statement_competitor_data_warehouse.rpt_refresh_error_logs (
            log_id, execution_id, batch_id, error_timestamp, procedure_name, error_type, error_details
        )
        VALUES (
            GENERATE_UUID(), v_execution_id, v_batch_id, CURRENT_TIMESTAMP(),
            'sp_refresh_report_tables', 'INFO_STAGE_START', 'Starting report table refresh'
        );

        -- 1. All products with lifecycle status (pages 1, 3 and 6).
        CREATE OR REPLACE TABLE statement_competitor_data_warehouse.rpt_market_products
        OPTIONS(description="Snapshot of gold_market_products for Data Studio. Rebuilt by sp_refresh_report_tables (step 9); do not edit.")
        AS
        SELECT *, CURRENT_TIMESTAMP() AS refreshed_at
        FROM statement_competitor_data_warehouse.gold_market_products;

        -- 2. Client items against comparable competitor stock (page 2).
        CREATE OR REPLACE TABLE statement_competitor_data_warehouse.rpt_client_price_position
        OPTIONS(description="Snapshot of gold_client_price_position for Data Studio. Rebuilt by sp_refresh_report_tables (step 9); do not edit.")
        AS
        SELECT *, CURRENT_TIMESTAMP() AS refreshed_at
        FROM statement_competitor_data_warehouse.gold_client_price_position;

        -- 3. Attribute premiums against the category median (page 4).
        CREATE OR REPLACE TABLE statement_competitor_data_warehouse.rpt_value_drivers
        OPTIONS(description="Snapshot of gold_value_drivers for Data Studio. Rebuilt by sp_refresh_report_tables (step 9); do not edit.")
        AS
        SELECT *, CURRENT_TIMESTAMP() AS refreshed_at
        FROM statement_competitor_data_warehouse.gold_value_drivers;

        -- 4. One row per sale (page 5).
        CREATE OR REPLACE TABLE statement_competitor_data_warehouse.rpt_sales
        OPTIONS(description="Snapshot of gold_sales for Data Studio. Rebuilt by sp_refresh_report_tables (step 9); do not edit.")
        AS
        SELECT *, CURRENT_TIMESTAMP() AS refreshed_at
        FROM statement_competitor_data_warehouse.gold_sales;

        -- Row counts for the completion log.
        SET v_summary = FORMAT(
            'Report tables refreshed: rpt_market_products %d, rpt_client_price_position %d, rpt_value_drivers %d, rpt_sales %d rows.',
            (SELECT COUNT(*) FROM statement_competitor_data_warehouse.rpt_market_products),
            (SELECT COUNT(*) FROM statement_competitor_data_warehouse.rpt_client_price_position),
            (SELECT COUNT(*) FROM statement_competitor_data_warehouse.rpt_value_drivers),
            (SELECT COUNT(*) FROM statement_competitor_data_warehouse.rpt_sales));

        -- Log completion.
        INSERT INTO statement_competitor_data_warehouse.rpt_refresh_error_logs (
            log_id, execution_id, batch_id, error_timestamp, procedure_name, error_type, error_details
        )
        VALUES (
            GENERATE_UUID(), v_execution_id, v_batch_id, CURRENT_TIMESTAMP(),
            'sp_refresh_report_tables', 'INFO_STAGE_COMPLETE', v_summary
        );

    EXCEPTION WHEN ERROR THEN
        SET v_error_msg = @@error.message;

        -- Log the error.
        INSERT INTO statement_competitor_data_warehouse.rpt_refresh_error_logs (
            log_id, execution_id, batch_id, error_timestamp, procedure_name, error_type, error_details
        )
        VALUES (
            GENERATE_UUID(), v_execution_id, v_batch_id, CURRENT_TIMESTAMP(),
            'sp_refresh_report_tables', 'REPORT_REFRESH_FAILURE', v_error_msg
        );

        -- Re-raise so the caller sees the failure.
        RAISE USING MESSAGE = FORMAT('sp_refresh_report_tables failed [Execution ID: %s]: %s', v_execution_id, v_error_msg);
    END;
END;


/*
===============================================================================
Tests (run manually)
===============================================================================
-- Refresh the report tables.
CALL statement_competitor_data_warehouse.sp_refresh_report_tables();

-- Latest run: start and completion (expect INFO_STAGE_COMPLETE with four row counts).
SELECT error_timestamp, error_type, error_details
FROM statement_competitor_data_warehouse.rpt_refresh_error_logs
WHERE execution_id = (
    SELECT execution_id
    FROM statement_competitor_data_warehouse.rpt_refresh_error_logs
    ORDER BY error_timestamp DESC
    LIMIT 1
)
ORDER BY error_timestamp;

-- Each report table matches its view (expect equal counts in each pair).
SELECT
    (SELECT COUNT(*) FROM statement_competitor_data_warehouse.rpt_market_products) AS rpt_market_products,
    (SELECT COUNT(*) FROM statement_competitor_data_warehouse.gold_market_products) AS gold_market_products,
    (SELECT COUNT(*) FROM statement_competitor_data_warehouse.rpt_client_price_position) AS rpt_client_price_position,
    (SELECT COUNT(*) FROM statement_competitor_data_warehouse.gold_client_price_position) AS gold_client_price_position;
*/
