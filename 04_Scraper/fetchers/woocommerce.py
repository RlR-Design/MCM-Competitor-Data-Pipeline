"""
WooCommerce: the public Store API (/wp-json/wc/store/v1/products, 100 per page).
A product is available when it is in stock and purchasable. Prices come in
minor units (cents).
"""

import html
from decimal import Decimal
from typing import List, Optional

from common import RawProduct, clean_title, cut_boilerplate, html_to_text, plain_price, utc_now

# Shop navigation categories that say nothing about the item.
_SKIP_CATEGORIES = {"new arrivals", "sale", "uncategorized"}


def fetch(shop, http, run, limit: Optional[int] = None) -> List[RawProduct]:
    products: List[RawProduct] = []
    page = 1
    while True:
        resp = http.get(f"{shop.base_url}/wp-json/wc/store/v1/products",
                        params={"per_page": 100, "page": page})
        if resp is None:
            raise RuntimeError("Store API not found (is the shop still on WooCommerce?)")
        run.pages_scraped += 1
        for item in resp.json():
            row = _row(shop, item)
            if row:
                products.append(row)
        if limit and len(products) >= limit:
            return products[:limit]
        if page >= int(resp.headers.get("X-WP-TotalPages", page)):
            break
        page += 1
    return products


def _row(shop, item) -> Optional[RawProduct]:
    if not (item.get("is_in_stock") and item.get("is_purchasable")):
        return None
    prices = item.get("prices") or {}
    minor = int(prices.get("currency_minor_unit", 2))
    raw = prices.get("price")
    price = plain_price(Decimal(raw) / (10 ** minor)) if raw else ""
    categories = [html.unescape(c["name"]) for c in item.get("categories", [])
                  if c.get("name") and html.unescape(c["name"]).lower() not in _SKIP_CATEGORIES]
    text = html_to_text(item.get("description") or "") or html_to_text(item.get("short_description") or "")
    hints = {"tags": ", ".join(t["name"] for t in item.get("tags", []) if t.get("name"))}
    regular = prices.get("regular_price")
    if item.get("on_sale") and regular:
        hints["compare_at_price"] = plain_price(Decimal(regular) / (10 ** minor))
    return RawProduct(
        shop_name=shop.name,
        url=item["permalink"],
        title=clean_title(item.get("name", "")),
        price=price,
        scraped_at=utc_now(),
        description=cut_boilerplate(text, shop.boilerplate),
        source_category=", ".join(categories),
        hints={k: v for k, v in hints.items() if v},
    )
