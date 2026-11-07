/*
===============================================================================
Script   : 10_create_gold_client_views.sql
Layer    : Gold
Purpose  : Views about the client's own shop:
             gold_client_price_position  each client item priced against
                                         comparable competitor stock
           The client's shop is the one with is_client = TRUE in
           ref_shop_locations (set by 04a_seed_shops.sql).
           Data Studio reads the snapshot rpt_client_price_position, rebuilt
           by sp_refresh_report_tables (step 9), not this view.
When     : Initial setup, after 07_create_gold_market_views.sql.
           Re-run after any change to this file, then CALL
           sp_refresh_report_tables() to refresh the snapshot. Safe to re-run.
Warning  : Views hold no data. Returns no rows if no shop is marked
           is_client. Medians and percentages cannot be re-aggregated:
           filter, do not sum or average them in Data Studio.
===============================================================================
*/

-- -----------------------------------------------------------------------------
-- gold_client_price_position: is each client item priced above or below
-- comparable competitor stock? One row per active client item.
--
-- Comparables = active competitor listings with a price, matched at the most
-- specific level with 3+ comparables from 2+ shops, falling back to the category:
--   1 Category, material and maker   2 Category and maker
--   3 Category and material          4 Category
-- Material ignores 'Solid' / 'Veneer' (Solid Kiaat = Kiaat). Maker is the
-- manufacturer ('John Tabraham for DS Vorster' = DS Vorster).
--
-- Prices are compared per piece. set_size is read from the title: 'Pair' = 2,
-- 'Set of 6' or 'Set of Six' = 6, a leading '4 x' = 4; anything else = 1.
-- Dining Sets are always 1 (a table and chairs are not N of one item).
-- Market figures are shown for the item's own set size, so a pair is compared
-- with twice the per-piece market price.
--
-- price_position: below p25 = Below market, above p75 = Above market,
-- otherwise In line with market. Fewer than 3 comparables or a single shop =
-- Too few comparables.
-- match_quality: Strong = matched on material or maker and is_reliable;
-- Fair = matched on material or maker, not reliable; Weak = category only or
-- too few comparables.
-- is_reliable = 5+ comparables from 2+ shops.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.gold_client_price_position
OPTIONS(description="Each active client item against comparable competitor stock, per piece: market quartiles for the item's set size, price gap, position (below, in line with or above market) and match quality")
AS
-- Active priced products with client flag, matching attributes and set size.
WITH sized AS (
    SELECT
        p.product_id,
        p.shop_name,
        p.category,
        COALESCE(r.is_client, FALSE) AS is_client,
        CAST(p.asking_price AS FLOAT64) AS asking_price,
        IF(p.material = 'Unknown', NULL,
           REGEXP_REPLACE(REGEXP_REPLACE(p.material, r'^Solid ', ''), r' Veneer$', '')) AS material_family,
        IF(p.maker = 'Unknown', NULL, REGEXP_REPLACE(p.maker, r'^.* for ', '')) AS maker_brand,
        CASE
            WHEN p.category = 'Dining Sets' THEN 1
            WHEN REGEXP_CONTAINS(LOWER(p.title), r'\bset of \d+\b')
                THEN SAFE_CAST(REGEXP_EXTRACT(LOWER(p.title), r'\bset of (\d+)\b') AS INT64)
            WHEN REGEXP_CONTAINS(LOWER(p.title), r'\bset of (two|three|four|five|six|seven|eight|ten|twelve)\b')
                THEN CASE REGEXP_EXTRACT(LOWER(p.title), r'\bset of (two|three|four|five|six|seven|eight|ten|twelve)\b')
                         WHEN 'two' THEN 2 WHEN 'three' THEN 3 WHEN 'four' THEN 4
                         WHEN 'five' THEN 5 WHEN 'six' THEN 6 WHEN 'seven' THEN 7
                         WHEN 'eight' THEN 8 WHEN 'ten' THEN 10 WHEN 'twelve' THEN 12
                     END
            -- Leading count only ('4 x Dining Chairs'), so dimensions ('148 x 68') never match.
            WHEN REGEXP_CONTAINS(p.title, r'^\s*\d{1,2}\s?[xX]\s')
                THEN SAFE_CAST(REGEXP_EXTRACT(p.title, r'^\s*(\d{1,2})\s?[xX]\s') AS INT64)
            WHEN REGEXP_CONTAINS(LOWER(p.title), r'\bpair\b') THEN 2
            ELSE 1
        END AS raw_set_size
    FROM statement_competitor_data_warehouse.gold_market_products p
    LEFT JOIN statement_competitor_data_warehouse.ref_shop_locations r
        ON LOWER(r.shop_name) = LOWER(p.shop_name)
    WHERE p.is_active
      AND p.asking_price > 0
),
-- Per-piece price. Implausible set sizes fall back to 1.
products AS (
    SELECT
        * EXCEPT (raw_set_size),
        IF(raw_set_size BETWEEN 2 AND 12, raw_set_size, 1) AS set_size,
        asking_price / IF(raw_set_size BETWEEN 2 AND 12, raw_set_size, 1) AS unit_price
    FROM sized
),
-- One row per product per match level it can be matched on.
keyed AS (
    SELECT
        p.product_id,
        p.shop_name,
        p.is_client,
        p.unit_price,
        k.match_rank,
        k.match_level,
        k.match_key
    FROM products p,
    UNNEST([
        STRUCT(1 AS match_rank, 'Category, material and maker' AS match_level,
               IF(p.material_family IS NULL OR p.maker_brand IS NULL, NULL,
                  CONCAT(p.category, '|', p.material_family, '|', p.maker_brand)) AS match_key),
        STRUCT(2 AS match_rank, 'Category and maker' AS match_level,
               IF(p.maker_brand IS NULL, NULL, CONCAT(p.category, '|', p.maker_brand)) AS match_key),
        STRUCT(3 AS match_rank, 'Category and material' AS match_level,
               IF(p.material_family IS NULL, NULL, CONCAT(p.category, '|', p.material_family)) AS match_key),
        STRUCT(4 AS match_rank, 'Category' AS match_level, p.category AS match_key)
    ]) AS k
    WHERE k.match_key IS NOT NULL
),
-- Competitor per-piece price quartiles per match level and key: [min, p25, median, p75, max].
market AS (
    SELECT
        match_rank,
        match_key,
        COUNT(*) AS comparables,
        COUNT(DISTINCT shop_name) AS comparable_shops,
        APPROX_QUANTILES(unit_price, 4) AS q
    FROM keyed
    WHERE NOT is_client
    GROUP BY match_rank, match_key
),
-- Most specific match with 3+ comparables from 2+ shops, falling back to the category.
best_match AS (
    SELECT
        k.product_id,
        ARRAY_AGG(STRUCT(k.match_rank, k.match_level, m.comparables, m.comparable_shops, m.q)
                  ORDER BY k.match_rank LIMIT 1)[OFFSET(0)] AS m
    FROM keyed k
    JOIN market m USING (match_rank, match_key)
    WHERE k.is_client
      AND ((m.comparables >= 3 AND m.comparable_shops >= 2) OR k.match_rank = 4)
    GROUP BY k.product_id
),
-- Position and reliability per client item.
scored AS (
    SELECT
        p.product_id,
        p.material_family,
        p.maker_brand,
        p.set_size,
        p.unit_price,
        b.m,
        CASE
            WHEN b.m.comparables IS NULL THEN 'No comparables'
            WHEN b.m.comparables < 3 OR b.m.comparable_shops < 2 THEN 'Too few comparables'
            WHEN p.unit_price < b.m.q[SAFE_OFFSET(1)] THEN 'Below market'
            WHEN p.unit_price > b.m.q[SAFE_OFFSET(3)] THEN 'Above market'
            ELSE 'In line with market'
        END AS price_position,
        COALESCE(b.m.comparables >= 5 AND b.m.comparable_shops >= 2, FALSE) AS is_reliable
    FROM products p
    LEFT JOIN best_match b USING (product_id)
    WHERE p.is_client
)
SELECT
    c.product_id,
    c.url,
    c.title,
    c.shop_name,
    c.category,
    c.maker,
    s.maker_brand,
    c.material,
    s.material_family,
    c.era,
    c.condition,
    c.status,
    s.set_size,
    c.asking_price,
    ROUND(s.unit_price, 2) AS unit_price,
    c.days_on_market,
    c.first_seen_at,
    s.m.match_level,
    COALESCE(s.m.comparables, 0) AS comparables,
    COALESCE(s.m.comparable_shops, 0) AS comparable_shops,
    ROUND(s.m.q[SAFE_OFFSET(0)] * s.set_size, 2) AS market_min,
    ROUND(s.m.q[SAFE_OFFSET(1)] * s.set_size, 2) AS market_p25,
    ROUND(s.m.q[SAFE_OFFSET(2)] * s.set_size, 2) AS market_median,
    ROUND(s.m.q[SAFE_OFFSET(3)] * s.set_size, 2) AS market_p75,
    ROUND(s.m.q[SAFE_OFFSET(4)] * s.set_size, 2) AS market_max,
    ROUND(c.asking_price - s.m.q[SAFE_OFFSET(2)] * s.set_size, 2) AS price_gap,
    ROUND((SAFE_DIVIDE(s.unit_price, s.m.q[SAFE_OFFSET(2)]) - 1) * 100, 1) AS price_gap_pct,
    s.price_position,
    CASE
        WHEN s.price_position IN ('No comparables', 'Too few comparables') OR s.m.match_rank = 4 THEN 'Weak'
        WHEN s.is_reliable THEN 'Strong'
        ELSE 'Fair'
    END AS match_quality,
    s.is_reliable
FROM statement_competitor_data_warehouse.gold_market_products c
JOIN scored s USING (product_id);


/*
===============================================================================
Tests (run manually)
===============================================================================
-- View exists (expect table_type = VIEW).
SELECT table_name, table_type
FROM `statement_competitor_data_warehouse.INFORMATION_SCHEMA.TABLES`
WHERE table_name = 'gold_client_price_position';

-- Exactly one shop is marked as the client (expect 1).
SELECT COUNTIF(is_client) AS client_shops
FROM statement_competitor_data_warehouse.ref_shop_locations;

-- One row per active priced client item (expect equal counts).
SELECT
    (SELECT COUNT(*) FROM statement_competitor_data_warehouse.gold_client_price_position) AS view_rows,
    (SELECT COUNT(*)
     FROM statement_competitor_data_warehouse.gold_market_products p
     JOIN statement_competitor_data_warehouse.ref_shop_locations r ON LOWER(r.shop_name) = LOWER(p.shop_name)
     WHERE r.is_client AND p.is_active AND p.asking_price > 0) AS client_items;

-- Items per position and match quality.
SELECT price_position, match_quality, COUNT(*) AS items
FROM statement_competitor_data_warehouse.gold_client_price_position
GROUP BY price_position, match_quality
ORDER BY price_position, match_quality;

-- Set sizes read from titles (check pairs and sets look right).
SELECT set_size, title, asking_price, unit_price
FROM statement_competitor_data_warehouse.gold_client_price_position
WHERE set_size > 1
ORDER BY set_size DESC;

-- No reliable match from a single shop (expect 0).
SELECT COUNT(*) AS single_shop_reliable
FROM statement_competitor_data_warehouse.gold_client_price_position
WHERE is_reliable AND comparable_shops < 2;

-- Client stock, most overpriced first.
SELECT title, category, set_size, asking_price, match_level, match_quality, comparables,
       comparable_shops, market_p25, market_median, market_p75, price_gap_pct, price_position
FROM statement_competitor_data_warehouse.gold_client_price_position
ORDER BY price_gap_pct DESC;
*/
