"""
Example shop list. Copy to shops_config.py (git-ignored) and fill in the real shops.
One entry per shop; the name must match ref_shop_locations exactly.
"""

from shops import Shop

SHOPS = [
    # Shopify: whole catalogue from /products.json, available variants only.
    Shop("shop_1", "shopify", "https://www.shop-1.example",
         "Gauteng", "Pretoria", -25.70, 28.20,
         boilerplate=(r"Shipping Information", r"Disclaimer")),
    # Shopify whose feed is mostly sold items with the live stock at the front:
    # end the feed read after 2 pages in a row without an available product.
    # Switch it on only after the shadow check in the status report shows "0 lost".
    Shop("shop_6", "shopify", "https://shop-6.example",
         "Gauteng", "Johannesburg", -26.10, 28.00,
         early_stop_pages=2),
    # WooCommerce: public Store API.
    Shop("shop_2", "woocommerce", "https://shop-2.example",
         "Western Cape", "Cape Town", -33.90, 18.60,
         boilerplate=(r"Returns Procedure",)),
    # Pagelayer / Kkart: listing pages per category slug, then product pages.
    Shop("shop_3", "pagelayer", "https://shop-3.example",
         "Gauteng", "Johannesburg", -26.10, 28.00,
         boilerplate=(r"Shipping\s*&\s*Delivery\s*Policy",),
         options={"categories": ["furniture", "tableware"]}),
    # Wix: store products sitemap, then product pages (JSON-LD availability).
    # sold_categories: for shops that move sold items to a category instead of marking them out of stock.
    Shop("shop_4", "wix", "https://www.shop-4.example",
         "Western Cape", "Cape Town", -33.90, 18.50,
         options={"sold_categories": ["Sold"]}),
]
