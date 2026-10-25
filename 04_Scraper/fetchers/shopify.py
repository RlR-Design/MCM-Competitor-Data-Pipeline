"""
Shopify: the public /products.json feed (250 products per page, whole catalogue).
A product is available when at least one variant is. Products with several
variants are separate items with their own price (some shops price sold
variants at R1,111,111.00), so each available variant is its own row with
URL .../products/<handle>?variant=<id>.
"""

from typing import List, Optional

from common import RawProduct, clean_title, cut_boilerplate, html_to_text, plain_price, utc_now


def fetch(shop, http, run, limit: Optional[int] = None) -> List[RawProduct]:
    # Shopify rate-limits per client across all its stores; keep feed requests spaced out.
    http.delay = max(http.delay, 2.0)
    products: List[RawProduct] = []
    page = 1
    while True:
        resp = http.get(f"{shop.base_url}/products.json", params={"limit": 250, "page": page})
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
