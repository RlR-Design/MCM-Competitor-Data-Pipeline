"""
Pagelayer / Kkart (SitePad) shops: category listing pages (/product-category/<slug>/page/<n>/),
then each product page. The shop removes the price and the Add To Cart button
when an item sells, so a product is available only when it has both.
"""

import json
import re
from typing import List, Optional

from bs4 import BeautifulSoup

from common import FetchError, RawProduct, clean_title, cut_boilerplate, html_to_text, plain_price, utc_now


def fetch(shop, http, run, limit: Optional[int] = None) -> List[RawProduct]:
    links = _product_links(shop, http, run)
    products: List[RawProduct] = []
    failed = 0
    for url in links:
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


def _product_links(shop, http, run) -> List[str]:
    prefix = shop.base_url.split("://", 1)[1] + "/product/"
    links: List[str] = []
    for slug in shop.options.get("categories", []):
        page = 1
        while True:
            url = f"{shop.base_url}/product-category/{slug}/" + (f"page/{page}/" if page > 1 else "")
            resp = http.get(url)
            if resp is None:
                break
            run.pages_scraped += 1
            soup = BeautifulSoup(resp.text, "html.parser")
            new = 0
            for a in soup.find_all("a", href=True):
                href = a["href"].split("?")[0].split("#")[0].replace("http://", "https://")
                if href.startswith("https://" + prefix) and href not in links:
                    links.append(href)
                    new += 1
            if not new:
                break
            page += 1
    return links


def _product(shop, http, url) -> Optional[RawProduct]:
    resp = http.get(url)
    if resp is None:
        return None
    soup = BeautifulSoup(resp.text, "html.parser")
    page_text = soup.get_text(" ", strip=True)

    amount = soup.find("input", {"name": "amount"})
    price = plain_price(amount.get("value")) if amount else ""
    if not price:
        for el in soup.select("[class*=price]"):
            price = plain_price(el.get_text(strip=True))
            if price:
                break
    if not price or "add to cart" not in page_text.lower():
        return None

    title_el = soup.find(class_="kkart-title") or soup.find("h1")
    title = title_el.get_text(" ", strip=True) if title_el else ""
    if not title:
        og = soup.find("meta", property="og:title")
        title = (og.get("content", "") if og else "").rsplit(" - ", 1)[0]

    content = soup.find("div", class_="pagelayer-post-excerpt") or soup.find("div", class_="entry-content")
    description = cut_boilerplate(html_to_text(str(content)) if content else "", shop.boilerplate)

    return RawProduct(
        shop_name=shop.name,
        url=url,
        title=clean_title(title),
        price=price,
        scraped_at=utc_now(),
        description=description,
        source_category=_breadcrumb_category(soup),
    )


def _breadcrumb_category(soup) -> str:
    for script in soup.find_all("script", type="application/ld+json"):
        try:
            data = json.loads(script.string or "{}")
        except ValueError:
            continue
        if isinstance(data, dict) and data.get("@type") == "BreadcrumbList":
            names = [i.get("item", {}).get("name", "") for i in data.get("itemListElement", [])]
            names = [re.sub(r"\s+", " ", n).strip() for n in names[1:] if n]
            return " > ".join(names)
    return ""
