/*
===============================================================================
Script   : 12_sp_snapshot_pipeline_vitals.sql
Layer    : Monitoring
Purpose  : Freezes the Pipeline Vitals dashboard for the latest pipeline run:
           copies the rows of every mon_dash_ view (01_DDL/13) into
           ops_vitals_snapshots, one row per view, as a JSON array in
           row_order. The weekly report for that run reads these rows, so
           its numbers never change afterwards.
When     : Deploy at setup. Called every Monday by the scheduled task that
           makes the weekly report (03_Documentation/Pipeline_Vitals_Dashboard.md),
           after the pipeline has run. Not a pipeline step: a failure here
           never affects the warehouse.
Requires : 01_DDL/12 and 01_DDL/13 deployed; at least one pipeline run.
Params   : p_replace  FALSE (default): keep an existing snapshot of the run
                      and do nothing. TRUE: take it again (overwrites the
                      frozen record of that run).
Logs     : None. ops_vitals_snapshots is its own record (taken_at, row_count).
           Errors are raised to the caller.
Warning  : The mon_dash_ views always describe the latest run, so only the
           latest run can be snapshotted. Take the snapshot before the next
           run starts.
===============================================================================
*/

CREATE OR REPLACE PROCEDURE statement_competitor_data_warehouse.sp_snapshot_pipeline_vitals (IN p_replace BOOL)
BEGIN
    DECLARE v_run STRING;
    DECLARE v_taken TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
    DECLARE v_existing INT64;

    -- The run the views describe.
    SET v_run = (
        SELECT run_batch_id
        FROM statement_competitor_data_warehouse.mon_pipeline_runs
        WHERE is_latest_run
    );
    IF v_run IS NULL THEN
        RAISE USING MESSAGE = 'sp_snapshot_pipeline_vitals: no pipeline run to snapshot.';
    END IF;

    SET v_existing = (
        SELECT COUNT(*)
        FROM statement_competitor_data_warehouse.ops_vitals_snapshots
        WHERE run_batch_id = v_run
    );

    IF v_existing > 0 AND NOT COALESCE(p_replace, FALSE) THEN
        SELECT v_run AS run_batch_id, 'kept' AS result,
               'A snapshot of this run already exists. CALL with TRUE to take it again.' AS note;
    ELSE
        BEGIN TRANSACTION;

        DELETE FROM statement_competitor_data_warehouse.ops_vitals_snapshots
        WHERE run_batch_id = v_run;

        -- One row per mon_dash_ view, so a new dashboard view is frozen without changing this procedure.
        FOR v IN (
            SELECT table_name
            FROM `statement_competitor_data_warehouse.INFORMATION_SCHEMA.VIEWS`
            WHERE STARTS_WITH(table_name, 'mon_dash_')
            ORDER BY table_name
        )
        DO
            EXECUTE IMMEDIATE FORMAT("""
                INSERT INTO statement_competitor_data_warehouse.ops_vitals_snapshots
                    (run_batch_id, dataset, taken_at, row_count, rows_json)
                SELECT @run, @ds, @taken, COUNT(*),
                       COALESCE(TO_JSON_STRING(ARRAY_AGG(t ORDER BY t.row_order)), '[]')
                FROM statement_competitor_data_warehouse.%s AS t
            """, v.table_name)
            USING v_run AS run, SUBSTR(v.table_name, 10) AS ds, v_taken AS taken;
        END FOR;

        COMMIT TRANSACTION;

        SELECT v_run AS run_batch_id, 'taken' AS result,
               FORMAT('%d views frozen at %t.',
                      (SELECT COUNT(*) FROM statement_competitor_data_warehouse.ops_vitals_snapshots WHERE run_batch_id = v_run),
                      v_taken) AS note;
    END IF;
END;


/*
===============================================================================
Tests (run manually)
===============================================================================
-- Take the snapshot of the latest run (keeps an existing one).
CALL statement_competitor_data_warehouse.sp_snapshot_pipeline_vitals(FALSE);

-- What was frozen for the latest run (expect one row per mon_dash_ view, 9 today).
SELECT dataset, row_count, taken_at, LENGTH(rows_json) AS json_chars
FROM statement_competitor_data_warehouse.ops_vitals_snapshots
WHERE run_batch_id = (SELECT run_batch_id FROM statement_competitor_data_warehouse.mon_pipeline_runs WHERE is_latest_run)
ORDER BY dataset;

-- Frozen rows match the live views (expect equal counts while no new run has happened).
SELECT s.dataset, s.row_count AS frozen_rows,
       (SELECT COUNT(*) FROM statement_competitor_data_warehouse.mon_dash_problems) AS live_problem_rows
FROM statement_competitor_data_warehouse.ops_vitals_snapshots s
WHERE s.dataset = 'problems'
ORDER BY s.taken_at DESC
LIMIT 1;
*/
