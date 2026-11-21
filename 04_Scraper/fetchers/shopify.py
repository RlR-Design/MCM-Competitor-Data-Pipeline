"""
Shopify: the public /products.json feed (250 products per page, whole catalogue
including sold items). A product is available when at least one variant is.
Products with several variants are separate items with their own price (some
shops price sold variants at R1,111,111.00), so each available variant is its
own row with URL .../products/<handle>?variant=<id>.

Read in sessions, spread over the week (since 2026-11 Shopify allows only a
couple of feed pages per shop before refusing for an hour or more):
  1. Feed pages: at most SESSION_REQUESTS per session; stop at the first refusal
     and continue from that page in the next session.
  2. Completeness check: once the last page is read, the shop's product sitemap
     (every product the shop lists, sold ones included) is compared with the
     products seen in the feed.
  3. Gaps: a product in the sitemap but not seen in the feed (pages shift when a
     shop deletes a product during the week) is read on its own from
     /products/<handle>.js, under the same per-session limit.
The shop is complete when all three are done. State is a JSON-ready dict kept
by main.py in the week's progress file.
"""

import re
from dataclasses import asdict
from typing import List, Optional
from urllib.parse import unquote

from common import BlockedError, RawProduct, clean_title, cut_boilerplate, html_to_text, plain_price, utc_now

PAGE_SIZE = 250
SESSION_REQUESTS = 2            # feed pages + gap products per shop per session
PAGE_DELAY = 20.0               # seconds between requests to one shop
MAX_GAP = 25                    # more sitemap products missing than this: something is off; flag, don't fetch


def new_state() -> dict:
    return {"next_page": 1, "pages_done": False,
            "seen": [], "rows": {}, "sitemap": None, "gone": [], "note": ""}


def products(state: dict) -> List[RawProduct]:
    return [RawProduct(**r) for rows in state["rows"].values() for r in rows]


def session(shop, http, run, state: dict, limit: Optional[int] = None) -> bool:
    """One session for one shop. Returns True when the shop is complete.
    A refusal ends the session for this shop (state keeps its place); other errors raise."""
    http.delay = max(http.delay, PAGE_DELAY)
    http.blocked_status.add(403)    # after many 429s Shopify answers 403 for a while
    http.stop_on_blocked = True
    seen = set(state["seen"])
    budget = SESSION_REQUESTS
    try:
        while not state["pages_done"]:
            if budget == 0:
                state["note"] = f"continues at page {state['next_page']}"
                return False
            budget -= 1
            page = state["next_page"]
            resp = http.get(f"{shop.base_url}/products.json", params={"limit": PAGE_SIZE, "page": page})
            if resp is None:
                raise RuntimeError("products.json not found (is the shop still on Shopify?)")
            run.pages_scraped += 1
            items = resp.json().get("products", [])
            for item in items:
                _store(shop, state, seen, item)
            if limit and sum(len(r) for r in state["rows"].values()) >= limit:
                state["pages_done"] = True
                state["sitemap"] = []           # quick test: no completeness check
                break
            # A short page is the last one (no request for an empty end page). Should
            # Shopify ever serve fewer than PAGE_SIZE per page, the sitemap check catches it.
            if len(items) < PAGE_SIZE:
                state["pages_done"] = True
            else:
                state["next_page"] = page + 1

        if state["sitemap"] is None:
            state["sitemap"] = _sitemap_handles(shop, http)

        missing = [h for h in state["sitemap"] if h not in seen and h not in state["gone"]]
        if len(missing) > MAX_GAP:
            raise RuntimeError(f"{len(missing)} products in the sitemap are not in products.json "
                               f"(more than {MAX_GAP}); check the feed")
        for i, handle in enumerate(missing):
            if budget == 0:
                state["note"] = f"{len(missing) - i} products from the sitemap still to read"
                return False
            budget -= 1
            resp = http.get(f"{shop.base_url}/products/{handle}.js")
            if resp is None:
                state["gone"].append(handle)    # removed since the sitemap was read
                continue
            _store(shop, state, seen, _from_js(resp.json()))
        state["note"] = (f"{len(state['sitemap'])} products in the sitemap, all read"
                         if state["sitemap"] else state["note"])
        return True
    except BlockedError as exc:
        state["note"] = f"refused ({exc.summary()}); continues next session"
        return False
    finally:
        state["seen"] = sorted(seen)


def _store(shop, state: dict, seen: set, item: dict) -> None:
    """Record one catalogue product: its available rows replace any earlier read."""
    handle = item.get("handle", "")
    seen.add(handle)
    rows = _rows(shop, item)
    if rows:
        state["rows"][handle] = [asdict(r) for r in rows]
    else:
        state["rows"].pop(handle, None)


def _sitemap_handles(shop, http) -> List[str]:
    """Handles of every product in the shop's sitemap (sold ones included)."""
    index = http.get(f"{shop.base_url}/sitemap.xml")
    if index is None:
        raise RuntimeError("sitemap.xml not found; completeness cannot be checked")
    handles: List[str] = []
    for url in re.findall(r"<loc>([^<]*sitemap_products[^<]*)</loc>", index.text):
        resp = http.get(url.replace("&amp;", "&"))
        if resp is None:
            raise RuntimeError(f"product sitemap not found: {url}")
        for loc in re.findall(r"<loc>([^<]*/products/[^<]*)</loc>", resp.text):
            handles.append(unquote(loc.rstrip("/").rsplit("/products/", 1)[1]))
    return handles


def _from_js(p: dict) -> dict:
    """A /products/<handle>.js product in the products.json shape (prices there are in cents)."""
    def money(v):
        if v in (None, ""):
            return None
        return f"{int(v) / 100:.2f}" if isinstance(v, int) else str(v)
    return {
        "handle": p.get("handle", ""),
        "title": p.get("title", ""),
        "body_html": p.get("description") or "",
        "product_type": p.get("type") or "",
        "tags": p.get("tags") or [],
        "vendor": p.get("vendor") or "",
        "variants": [{"id": v.get("id"), "title": v.get("title", ""), "available": v.get("available"),
                      "price": money(v.get("price")), "compare_at_price": money(v.get("compare_at_price"))}
                     for v in p.get("variants", [])],
    }


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
