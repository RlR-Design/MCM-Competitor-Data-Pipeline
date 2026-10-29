/*
===============================================================================
Script   : 04a_seed_shops.example.sql
Layer    : Reference
Purpose  : Example of 04a_seed_shops.sql, which seeds the real shops (local
           only, git-ignored): verified coordinates and the client's own shop
           (ref_shop_locations) and shop-specific rules (ref_shop_rules). Names and coordinates here are
           placeholders.
When     : Copy to 04a_seed_shops.sql, fill in the shops, run after
           04_create_reference_tables.sql. Safe to re-run.
Warning  : Shop names must match the scraper's shop names exactly.
           Seeds only insert missing rows. Edits made in the tables are kept.
===============================================================================
*/

-- Seed known shops that are not in the table yet.
MERGE statement_competitor_data_warehouse.ref_shop_locations AS target
USING (
    SELECT 'shop_1' AS shop_name, -25.70 AS latitude, 28.20 AS longitude UNION ALL
    SELECT 'shop_2', -26.10, 28.00 UNION ALL
    SELECT 'shop_3', -33.90, 18.60
) AS source
ON LOWER(target.shop_name) = LOWER(source.shop_name)
WHEN NOT MATCHED THEN
    INSERT (shop_name, latitude, longitude, updated_at)
    VALUES (source.shop_name, source.latitude, source.longitude, CURRENT_TIMESTAMP());

-- Mark the client's own shop if no shop is marked yet.
UPDATE statement_competitor_data_warehouse.ref_shop_locations
SET is_client = TRUE, updated_at = CURRENT_TIMESTAMP()
WHERE LOWER(shop_name) = LOWER('shop_2')
  AND NOT EXISTS (SELECT 1 FROM statement_competitor_data_warehouse.ref_shop_locations WHERE is_client);

-- Seed known shop exceptions that are not in the table yet.
-- Change them later with sp_set_shop_rule (02_Stored_Procedures/10).
MERGE statement_competitor_data_warehouse.ref_shop_rules AS target
USING (
    SELECT 'shop_1' AS shop_name, 0.3 AS max_quarantine_rate,
           'Removes the price of sold items; up to 30% rows without a price is normal' AS notes
) AS source
ON LOWER(target.shop_name) = LOWER(source.shop_name)
WHEN NOT MATCHED THEN
    INSERT (shop_name, max_quarantine_rate, notes, updated_at)
    VALUES (source.shop_name, source.max_quarantine_rate, source.notes, CURRENT_TIMESTAMP());


/*
===============================================================================
Tests (run manually)
===============================================================================
-- One location per shop.
SELECT shop_name, latitude, longitude, is_client, updated_at
FROM statement_competitor_data_warehouse.ref_shop_locations
ORDER BY shop_name;
*/
