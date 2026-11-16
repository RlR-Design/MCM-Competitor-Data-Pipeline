"""
Shopify: the public /products.json feed (250 products per page, whole catalogue).
A product is available when at least one variant is. Products with several
variants are separate items with their own price (some shops price sold
variants at R1,111,111.00), so each available variant is its own row with
URL .../products/<handle>?variant=<id>.
"""

import time
from typing import List, Optional

from common import FetchError, RawProduct, clean_title, cut_boilerplate, html_to_text, plain_price, utc_now


PAUSE_SECONDS = 900             # long pause when a page stays rate limited
MAX_PAUSES = 4


def fetch(shop, http, run, limit: Optional[int] = None) -> List[RawProduct]:
    # Shopify rate-limits per IP across all its stores and remembers recent requests:
    # big shops (whole catalogue incl. sold items, ~20 pages) hit 429 part-way (2026-11-14).
    # 20 s between pages; when a page stays limited, pause and continue from that page.
    # After many 429s Shopify answers 403 for a while, so retry that too.
    http.delay = max(http.delay, 20.0)
    http.retries = 3
    http.blocked_status.add(403)
    products: List[RawProduct] = []
    page = 1
    pauses = 0
    first_page_size = 0
    while True:
        try:
            resp = http.get(f"{shop.base_url}/products.json", params={"limit": 250, "page": page})
        except FetchError:
            # Still limited after the retries: pause long, then continue from this page
            # (starting over would request the earlier pages again).
            if pauses == MAX_PAUSES:
                raise
            pauses += 1
            print(f"    still rate limited on page {page}; pause {pauses} of {MAX_PAUSES}: "
                  f"{PAUSE_SECONDS // 60} min, then continue from page {page}", flush=True)
            time.sleep(PAUSE_SECONDS)
            continue
        if resp is None:
            raise RuntimeError("products.json not found (is the shop still on Shopify?)")
        run.pages_scraped += 1
        items = resp.json().get("products", [])
        if not items:
            break
        for item in items:
            products.extend(_rows(shop, item))
        if limit and len(products) >= limit:
            return products[:limit]
        # A page shorter than page 1 is the last one: skip the empty end page.
        # (Page 1's size is the reference, not a fixed 250, in case Shopify caps lower.)
        if page == 1:
            first_page_size = len(items)
        elif len(items) < first_page_size:
            break
        page += 1
    return products


def _rows(shop, item) -> List[RawProduct]:
    if "gift card" in (item.get("product_type") or "").lower() or "gift-card" in item.get("handle", ""):
        return []
    variants = [v for v in item.get("variants", []) if v.get("available")]
    if not variants:
        return []
    base_url = f"{shop.base_url}/products/{item['handle']}"
    title = clean_title(item.get("title", ""))
    description = cut_boilerplate(html_to_text(item.get("body_html") or ""), shop.boilerplate)
    hints = {
        "product_type": item.get("product_type") or "",
        "tags": ", ".join(item.get("tags") or [])[:300],
    }
    vendor = (item.get("vendor") or "").strip()
    if vendor and vendor.lower() != shop.name.lower():
        hints["vendor"] = vendor
    scraped_at = utc_now()
    several = len(item.get("variants", [])) > 1
    rows = []
    for v in variants:
        row_hints = dict(hints)
        if v.get("compare_at_price"):
            row_hints["compare_at_price"] = plain_price(v["compare_at_price"])
        rows.append(RawProduct(
            shop_name=shop.name,
            url=f"{base_url}?variant={v['id']}" if several else base_url,
            title=f"{title} - {clean_title(v.get('title', ''))}" if several else title,
            price=plain_price(v.get("price")),
            scraped_at=scraped_at,
            description=description,
            source_category=hints["product_type"],
            hints={k: val for k, val in row_hints.items() if val},
        ))
    return rows
