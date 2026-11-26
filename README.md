# MCM-Competitor-Data-Pipeline
A competitor data pipeline feeding a modern data warehouse in BigQuery for a Mid-century Modern furniture company. The warehouse is built in stages, and this is one of the pipelines that loads it.

## **1\. Executive Summary**

This project establishes an empirical pricing baseline and automated data pipeline for the South African mid-century modern (MCM) and vintage furniture market. Independent dealers and restorers, exemplified by **omitted**, frequently operate in a fragmented landscape relying on intuition or ad-hoc competitor checks. This often leads to mispriced inventory due to unstandardised listings, inconsistent timber classifications (e.g., Kiaat, Teak, Imbuia), and obscured designer attributions.

To resolve this, the project implements an end-to-end competitor data pipeline into the company's data warehouse, utilising a **Medallion Architecture (Bronze, Silver, Gold)** hosted on **Google Cloud BigQuery**. Custom Python web scrapers and cloud functions extract weekly/monthly listing feeds across key South African boutique storefronts and platforms (Shopify, WooCommerce, Wix). Data flows through robust staging validation, quarantine logging, and star-schema dimensional modelling. The final strategic output powers an interactive **Google Data Studio** KPI dashboard, delivering automated catalog tracking, regional demand analytics (Gauteng vs. Western Cape), turnover velocity metrics, and data-driven retail pricing intelligence.&nbsp;

## **2\. Problem Domain**

The South African vintage, retro, and mid-century modern furniture market operates through a niche network of boutique restorers, independent online stores, and secondary marketplace platforms (including stockists such as *content was deleted to preserve anonymity* and *omitted*). Unlike mass-market retail, vintage asset valuation depends heavily on scarce qualitative attributes: raw wood species, historical design attribution, physical restoration condition, era provenance, and regional demand dynamics.

## **3\. Problem Statement**

Independent furniture dealers in South Africa frequently set retail prices based on personal intuition or isolated competitor checks. Because item descriptions, wood species (such as Kiaat, Imbuia, and Teak), and designer attributions are unstandardised across platforms, businesses risk undervaluing rare inventory or locking up capital in overpriced, slow-moving stock. Without a centralised historical data repository, tracking market price drift and true inventory velocity across competitors remains unfeasible.

## **4\. Business Objectives**

* **Establish an Empirical Pricing Baseline:** Quantify median/quartile median and mean market values for MCM furniture across major South African digital sales channels.  
* **Isolate Value Drivers:** Identify specific item characteristics, timber types, and designer tags that drive measurable price premiums.  
* **Benchmark Inventory Velocity:** Calculate average days on market and turnover velocity to benchmark performance against regional competitors.  
* **Build a Scalable Data Pipeline:** Design a normalised database schema and automated ETL workflow capable of transitioning from static snapshots to scheduled monthly/weekly pipelines.  
* **Deliver Actionable Intelligence:** Deploy an intuitive Google Data Studio executive dashboard tracking key pricing matrices, inventory health, and regional demand concentrations.

## **5\. Stakeholders & Target Audience**

* **Vintage Furniture Business Owners & Restorers (omitted):** Require data-driven pricing models to optimise acquisition budgets, set competitive listing prices, and evaluate stock performance.  
* **E-commerce & Brand Strategists:** Require granular market intelligence to optimise product cataloguing, search keyword strategies, and collection structures across digital storefronts.


## **6\. How to Run**

All objects live in the BigQuery dataset `statement_competitor_data_warehouse`. Each script starts with a header (purpose, when to run, requirements, warnings) and ends with commented-out tests.

### Setup (once, in order)

For a clean rebuild, first run `01_DDL/00_reset_dataset.sql` (commented out by default). It drops every object in the dataset, including Bronze and price history, so use it only before real history exists.

| Step | Script | Creates |
|---|---|---|
| 1 | `01_DDL/01_create_dataset.sql` | Dataset |
| 2 | `01_DDL/02_create_bronze_tables.sql` | Bronze tables |
| 3 | `01_DDL/03_create_silver_tables.sql` | Silver tables, star schema, price history |
| 4 | `01_DDL/04_create_reference_tables.sql`, then `04a_seed_shops.sql` | `ref_shop_locations`, `ref_shop_rules`; 04a seeds the shops (local file; copy `04a_seed_shops.example.sql`) |
| 5 | `01_DDL/05_create_gold_views.sql` | Gold star schema views |
| 6 | `01_DDL/06_create_gold_lifecycle_views.sql` | Gold lifecycle and reporting views |
| 7 | `01_DDL/07_create_gold_market_views.sql` | Gold market insight views |
| 8 | `01_DDL/08_create_monitoring_views.sql` | Scrape monitoring views |
| 9 | `01_DDL/09_create_automation_tables.sql` | Trigger log for the automation |
| 10 | `01_DDL/10_create_gold_client_views.sql` | Gold views about the client's own shop |
| 11 | `01_DDL/11_create_report_tables.sql` | Log table for the report table refresh |
| 12 | `01_DDL/12_create_pipeline_monitoring_views.sql` | Pipeline monitoring views (steps, runs, shop freshness, warehouse size, BigQuery cost) |
| 13 | `01_DDL/13_create_dashboard_views.sql` | One view per Pipeline Vitals dashboard section, and the weekly snapshot table |
| 14 | `02_Stored_Procedures/01` to `12` | Stored procedures (`10` = `sp_set_shop_rule`, for maintenance; `11` = report refresh, step 9) |
| 15 | `05_Automation/` | Cloud Run function that runs the pipeline on each upload, and the weekly Mac scrape schedule (see its README) |

Checks for setup and after every run, with expected results: `07_Tests/pipeline_tests.sql`.

DDL scripts are safe to re-run: they never drop or overwrite data. Re-deploy a procedure script after changing it.

### Pipeline (per scraped CSV)

Automated: the Mac scrapes weekly and uploads to `incoming/` in the bucket; each upload runs the pipeline (`05_Automation/`). Manual run:

```sql
CALL statement_competitor_data_warehouse.sp_run_pipeline('gs://<bucket>/<file>.csv');
```

`sp_run_pipeline` runs these steps in order and stops at the first failure:

| Step | Procedure | Does |
|---|---|---|
| 1 | `sp_load_bronze_products` | Appends the CSV to Bronze as a new batch |
| 2 | `sp_validate_bronze_products` | Quarantines rows without a URL or parseable price |
| 3 | `sp_check_scrape_health` | Flags failed or partial shop scrapes (never stops the run) |
| 4 | `sp_load_silver_products` | Cleans the batch and merges new or changed products into Silver |
| 5 | `sp_validate_silver_products` | Quarantines rows without a shop name or valid price |
| 6 | `sp_normalise_silver_products` | Rebuilds dimensions and the fact table |
| 7 | `sp_load_dim_price_history` | Records price and availability changes (SCD Type 2) |
| 8 | `sp_reconciled_silver_products` | Runs integrity checks and logs any issues |
| 9 | `sp_refresh_report_tables` | Rebuilds the `rpt_*` report tables Data Studio reads |

Gold objects are views and need no load step. Step 9 saves four of them as report tables, so Data Studio reads one small table per chart instead of the full stack of views.

### Gold views for reporting

| View | Grain | Answers |
|---|---|---|
| `gold_products_flat` | product | All attributes, current price and status |
| `gold_sales` | sale | Every sale nationally |
| `gold_price_baseline` | segment | Price quartiles per category, material, maker, era, condition, region, shop |
| `gold_value_drivers` | category x attribute | Price premium of materials, makers, eras and conditions |
| `gold_market_monthly` | month x region x category | New listings, sales and prices over time |
| `gold_regional_demand` | region | Demand, stock and velocity per province |
| `gold_shop_scorecard` | shop | Competitor benchmark |
| `gold_client_price_position` | client item | Is each of the client's items priced below, in line with or above comparable competitor stock (per piece, so pairs and sets compare fairly) |

Medians are pre-computed per row: filter them in Data Studio, do not sum or average them.

### Report tables for Data Studio

Snapshots of Gold views, replaced by step 9 on every run (never edit them by hand). Each has a `refreshed_at` column. After changing a Gold view, `CALL sp_refresh_report_tables()`.

| Table | Snapshot of |
|---|---|
| `rpt_market_products` | `gold_market_products` |
| `rpt_client_price_position` | `gold_client_price_position` |
| `rpt_value_drivers` | `gold_value_drivers` |
| `rpt_sales` | `gold_sales` |

### Reference data

Maintained by hand, no redeploy needed:

- `ref_shop_locations`: verified shop coordinates, and `is_client` = TRUE for the client's own shop.
- `ref_shop_rules`: how each shop signals a sale (zero price, delisting grace period) and its scrape health thresholds. The `'*'` row is the default; a shop row overrides it per value. Set with `CALL sp_set_shop_rule(...)` (`02_Stored_Procedures/10`).

### Scrape health

`bronze_scrape_health` holds one row per shop per batch: `HEALTHY`, `WARNING` or `FAILED`, with the reasons. Failed scrapes are still loaded, but the Gold views ignore them when deciding whether a product was delisted.

Monitoring views:

- `mon_scrape_runs`: one row per run with overall status, shops per status, product totals and duration.
- `mon_scrape_shop_runs`: one row per shop per run with the scraper's report next to the warehouse checks.
- `mon_pipeline_events`, `mon_pipeline_step_runs`, `mon_pipeline_runs`: every log event, every step of every run, and one row per run with status, volumes and timings.
- `mon_shop_freshness`: Fresh, Stale or Critical per shop, with its last good scrape and failures in a row.
- `mon_warehouse_tables`, `mon_query_costs`: table sizes per layer, and BigQuery usage and cost per day.

These feed the **Pipeline Vitals** dashboard, a private Claude dashboard that queries them live (through the `mon_dash_` views of `01_DDL/13`) each time it opens. Every Thursday at 21:33, after the 19:00 upload and pipeline run, a scheduled task freezes that week's run (`sp_snapshot_pipeline_vitals`, `02_Stored_Procedures/12`, into `ops_vitals_snapshots`) and saves a frozen copy, "Pipeline Vitals: run of <date>". See `03_Documentation/Pipeline_Vitals_Dashboard.md`.

### Scrape run summary file

Upload next to the products CSV, in the same folder, named `<name>_run_summary.csv` (e.g. `MCM_All_products_2026-09-15.csv` and `MCM_All_products_2026-09-15_run_summary.csv`). It is optional; without it, only the warehouse-side checks run. `04_Scraper/scrape_run_summary.py` writes it.

| Column | Example | Meaning |
|---|---|---|
| `run_id` | `2b47d3b0-...` | Same for every shop in one run |
| `shop_name` | `shop_4` | Exactly as in the products CSV |
| `started_at` / `finished_at` | `2026-10-22 08:00:00` | UTC |
| `status` | `SUCCESS`, `PARTIAL`, `FAILED` | Scraper's own verdict |
| `pages_scraped` | `13` | Listing pages visited |
| `products_found` | `312` | Products extracted |
| `products_expected` | `312` | Count shown by the site, blank if not shown |
| `http_errors` / `retries` | `0` | Request failures and retries |
| `error_message` | `TimeoutError: ...` | Blank on success |
| `scraper_version` | `1.0.0` | Scraper release |
