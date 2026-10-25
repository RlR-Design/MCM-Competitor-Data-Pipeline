"""
Wix stores: every product URL from /store-products-sitemap.xml, then each
product page. Availability and price come from the page's JSON-LD Product
data (offers.availability InStock). Shops that keep sold items in stock but
move them to a category (e.g. "Sold") list it in options["sold_categories"].
The sitemap also lists sold items, so every page has to be opened.
"""

import json
import re
from typing import List, Optional

from bs4 import BeautifulSoup

from common import FetchError, RawProduct, clean_title, cut_boilerplate, html_to_text, plain_price, utc_now


def fetch(shop, http, run, limit: Optional[int] = None) -> List[RawProduct]:
    resp = http.get(f"{shop.base_url}/store-products-sitemap.xml")
    if resp is None:
        raise RuntimeError("store-products-sitemap.xml not found (is the shop still on Wix?)")
    run.pages_scraped += 1
    links = list(dict.fromkeys(
        u.strip() for u in re.findall(r"<loc>(.*?)</loc>", resp.text) if "/product-page/" in u))
    print(f"    {len(links)} product pages in the sitemap", flush=True)

    products: List[RawProduct] = []
    failed = 0
    for i, url in enumerate(links, 1):
        if i % 100 == 0:
            print(f"    {i}/{len(links)} pages checked, {len(products)} available", flush=True)
        try:
            row = _product(shop, http, url)
        except FetchError as exc:
            failed += 1
            print(f"    [!] {exc}", flush=True)
            continue
        if row:
            products.append(row)
            if limit and len(products) >= limit:
                break
    if failed:
        run.mark_partial(f"{failed} of {len(links)} product pages failed")
    return products


def _product(shop, http, url) -> Optional[RawProduct]:
    resp = http.get(url)
    if resp is None:
        return None
    soup = BeautifulSoup(resp.text, "html.parser")
    data = _product_ld(soup)
    if not data:
        return None
    offers = data.get("offers") or {}
    if isinstance(offers, list):
        offers = offers[0] if offers else {}
    if "InStock" not in str(offers.get("availability", "")):
        return None
    categories = _categories(resp.text)
    sold = {c.lower() for c in shop.options.get("sold_categories", [])}
    if sold & {c.lower() for c in categories}:
        return None
    price = plain_price(offers.get("price") or offers.get("lowPrice"))

    parts = []
    for hook in ("description", "info-section-description"):
        el = soup.find(attrs={"data-hook": hook})
        if el:
            text = html_to_text(str(el))
            if text and text not in parts:
                parts.append(text)
    description = "\n".join(parts) or (data.get("description") or "").strip()

    return RawProduct(
        shop_name=shop.name,
        url=url,
        title=clean_title(data.get("name", "")),
        price=price,
        scraped_at=utc_now(),
        description=cut_boilerplate(description, shop.boilerplate),
        source_category=", ".join(c for c in categories if c.lower() != "all products"),
    )


def _categories(page: str) -> List[str]:
    """Category names from the page's embedded product data (first "categories" list)."""
    match = re.search(r'"categories":\[(.*?)\]', page)
    if not match:
        return []
    names = re.findall(r'"name":"((?:[^"\\]|\\.)*)"', match.group(1))
    return [json.loads(f'"{n}"') for n in names]


def _product_ld(soup) -> Optional[dict]:
    for script in soup.find_all("script", type="application/ld+json"):
        try:
            data = json.loads(script.string or "{}")
        except ValueError:
            continue
        if isinstance(data, dict) and data.get("@type") == "Product":
            return data
    return None
