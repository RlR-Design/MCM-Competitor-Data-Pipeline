/*
===============================================================================
Script   : 10_create_gold_client_views.sql
Layer    : Gold
Purpose  : Views about the client's own shop for Data Studio:
             gold_client_price_position  each client item priced against
                                         comparable competitor stock
           The client's shop is the one with is_client = TRUE in
           ref_shop_locations (set by 04a_seed_shops.sql).
When     : Initial setup, after 07_create_gold_market_views.sql.
           Re-run after any change to this file. Safe to re-run.
Warning  : Views hold no data. Returns no rows if no shop is marked
           is_client. Medians and percentages cannot be re-aggregated:
           filter, do not sum or average them in Data Studio.
===============================================================================
*/

-- -----------------------------------------------------------------------------
-- gold_client_price_position: is each client item priced above or below
-- comparable competitor stock? One row per active client item.
-- Comparables = active competitor listings with a price, matched at the most
-- specific level with 3+ comparables, falling back to the category:
--   1 Category, material and maker   2 Category and maker
--   3 Category and material          4 Category
-- Material ignores 'Solid' / 'Veneer' (Solid Kiaat = Kiaat). Maker is the
-- manufacturer ('John Tabraham for DS Vorster' = DS Vorster).
-- price_position: below p25 = Below market, above p75 = Above market.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW statement_competitor_data_warehouse.gold_client_price_position
OPTIONS(description="Each active client item against comparable competitor stock: market quartiles, price gap and position (below, in line with or above market)")
AS
-- Active priced products with client flag and matching attributes.
WITH products AS (
    SELECT
        p.product_id,
        p.shop_name,
        p.category,
        COALESCE(r.is_client, FALSE) AS is_client,
        CAST(p.asking_price AS FLOAT64) AS asking_price,
        IF(p.material = 'Unknown', NULL,
           REGEXP_REPLACE(REGEXP_REPLACE(p.material, r'^Solid ', ''), r' Veneer$', '')) AS material_family,
        IF(p.maker = 'Unknown', NULL, REGEXP_REPLACE(p.maker, r'^.* for ', '')) AS maker_brand
    FROM statement_competitor_data_warehouse.gold_market_products p
    LEFT JOIN statement_competitor_data_warehouse.ref_shop_locations r
        ON LOWER(r.shop_name) = LOWER(p.shop_name)
    WHERE p.is_active
      AND p.asking_price > 0
),
-- One row per product per match level it can be matched on.
keyed AS (
    SELECT
        p.product_id,
        p.shop_name,
        p.is_client,
        p.asking_price,
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
-- Competitor price quartiles per match level and key: [min, p25, median, p75, max].
market AS (
    SELECT
        match_rank,
        match_key,
        COUNT(*) AS comparables,
        COUNT(DISTINCT shop_name) AS comparable_shops,
        APPROX_QUANTILES(asking_price, 4) AS q
    FROM keyed
    WHERE NOT is_client
    GROUP BY match_rank, match_key
),
-- Most specific match with 3+ comparables; the category is the fallback.
best_match AS (
    SELECT
        k.product_id,
        ARRAY_AGG(STRUCT(k.match_level, m.comparables, m.comparable_shops, m.q)
                  ORDER BY k.match_rank LIMIT 1)[OFFSET(0)] AS m
    FROM keyed k
    JOIN market m USING (match_rank, match_key)
    WHERE k.is_client
      AND (m.comparables >= 3 OR k.match_rank = 4)
    GROUP BY k.product_id
)
SELECT
    c.product_id,
    c.url,
    c.title,
    c.shop_name,
    c.category,
    c.maker,
    c.material,
    c.era,
    c.condition,
    c.status,
    c.asking_price,
    c.days_on_market,
    c.first_seen_at,
    b.m.match_level,
    COALESCE(b.m.comparables, 0) AS comparables,
    COALESCE(b.m.comparable_shops, 0) AS comparable_shops,
    ROUND(b.m.q[SAFE_OFFSET(0)], 2) AS market_min,
    ROUND(b.m.q[SAFE_OFFSET(1)], 2) AS market_p25,
    ROUND(b.m.q[SAFE_OFFSET(2)], 2) AS market_median,
    ROUND(b.m.q[SAFE_OFFSET(3)], 2) AS market_p75,
    ROUND(b.m.q[SAFE_OFFSET(4)], 2) AS market_max,
    ROUND(c.asking_price - b.m.q[SAFE_OFFSET(2)], 2) AS price_gap,
    ROUND((SAFE_DIVIDE(c.asking_price, b.m.q[SAFE_OFFSET(2)]) - 1) * 100, 1) AS price_gap_pct,
    CASE
        WHEN b.m.comparables IS NULL THEN 'No comparables'
        WHEN b.m.comparables < 3 THEN 'Too few comparables'
        WHEN c.asking_price < b.m.q[SAFE_OFFSET(1)] THEN 'Below market'
        WHEN c.asking_price > b.m.q[SAFE_OFFSET(3)] THEN 'Above market'
        ELSE 'In line with market'
    END AS price_position,
    COALESCE(b.m.comparables, 0) >= 5 AS is_reliable
FROM statement_competitor_data_warehouse.gold_market_products c
JOIN products p USING (product_id)
LEFT JOIN best_match b USING (product_id)
WHERE p.is_client;


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

-- Items per position and match level.
SELECT price_position, match_level, COUNT(*) AS items
FROM statement_competitor_data_warehouse.gold_client_price_position
GROUP BY price_position, match_level
ORDER BY price_position, match_level;

-- Client stock, most overpriced first.
SELECT title, category, asking_price, match_level, comparables, market_p25, market_median, market_p75,
       price_gap_pct, price_position
FROM statement_competitor_data_warehouse.gold_client_price_position
ORDER BY price_gap_pct DESC;
*/
