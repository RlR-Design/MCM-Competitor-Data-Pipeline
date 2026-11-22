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

Early stop (Shop.early_stop_pages, 2.4.0): some feeds are mostly an archive of
sold items with the live stock at the front (shop_6, 2026-11: all 107 available
products in the first 4 of 20 pages). For such a shop the feed read ends after
early_stop_pages pages in a row without an available product. The sitemap check
does not fit then (it would call every sold product in the unread pages
missing), so step 2 changes: every product the shop had available in its last
scrape (the reference, from main.py) must be seen in the pages read, or is read
on its own in step 3. More than MAX_GAP of them unseen means the live stock is
not where the early stop assumed: the early stop is undone for the week and the
rest of the feed is read, ending with the normal sitemap check. A shop without
a reference (first scrape) reads its whole feed.

Shadow check: a shop that reads its whole feed records what the early stop
would have done (the page it would have ended on, the reference products it
would have read on their own, the available products it would have lost), from
the per-page profile kept during the read. No extra requests. This is how the
early stop is tried on a shop before it is switched on.
"""

import re
from dataclasses import asdict
from typing import Callable, List, Optional
from urllib.parse import unquote

from common import BlockedError, RawProduct, clean_title, cut_boilerplate, html_to_text, plain_price, utc_now

PAGE_SIZE = 250
SESSION_REQUESTS = 2            # feed pages + gap products per shop per session
PAGE_DELAY = 20.0               # seconds between requests to one shop
MAX_GAP = 25                    # more sitemap products missing than this: something is off; flag, don't fetch
EARLY_STOP_PAGES = 2            # pages without an available product, for the shadow check of other shops


def new_state() -> dict:
    return {"next_page": 1, "pages_done": False,
            "seen": [], "rows": {}, "sitemap": None, "gone": [], "note": "",
            # 2.4.0. profile: one [page, products, available handles, reference handles]
            # per feed page read. reference: handles available in the last scrape.
            # early_stop: page the read ended on early; early_stop_undone: page of an
            # early stop taken back this week. shadow: the shadow check's result.
            "profile": [], "reference": None, "early_stop": None, "early_stop_undone": None,
            "shadow": None}


def _upgrade(state: dict) -> None:
    """Adds the 2.4.0 keys to state from a progress file written by an earlier version."""
    for key, value in new_state().items():
        state.setdefault(key, value)


def products(state: dict) -> List[RawProduct]:
    return [RawProduct(**r) for rows in state["rows"].values() for r in rows]


def handle_from_url(url: str) -> str:
    """The handle in .../products/<handle> or .../products/<handle>?variant=<id>."""
    if "/products/" not in url:
        return ""
    return unquote(url.split("/products/", 1)[1].split("?", 1)[0].strip("/"))


def session(shop, http, run, state: dict, limit: Optional[int] = None,
            reference: Optional[Callable[[], List[str]]] = None) -> bool:
    """One session for one shop. Returns True when the shop is complete.
    reference returns the URLs the shop had available in its last scrape (main.py);
    the early stop and the shadow check use it.
    A refusal ends the session for this shop (state keeps its place); other errors raise."""
    _upgrade(state)
    http.delay = max(http.delay, PAGE_DELAY)
    http.blocked_status.add(403)    # after many 429s Shopify answers 403 for a while
    http.stop_on_blocked = True
    seen = set(state["seen"])
    known = set(_reference(state, reference))
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
            available = [item.get("handle", "") for item in items if _store(shop, state, seen, item)]
            state["profile"].append([page, len(items), available,
                                     [item.get("handle", "") for item in items if item.get("handle", "") in known]])
            if limit and sum(len(r) for r in state["rows"].values()) >= limit:
                state["pages_done"] = True
                state["sitemap"] = []           # quick test: no completeness check
                break
            # A short page is the last one (no request for an empty end page). Should
            # Shopify ever serve fewer than PAGE_SIZE per page, the sitemap check catches it.
            if len(items) < PAGE_SIZE:
                state["pages_done"] = True
            elif _early_stop_now(shop, state):
                state["pages_done"] = True
                state["early_stop"] = page
                print(f"   early stop after page {page}: {_empty_run(state['profile'])} pages without "
                      f"an available product", flush=True)
            else:
                state["next_page"] = page + 1

        if state["early_stop"]:
            missing = [h for h in state["reference"] if h not in seen and h not in state["gone"]]
            if len(missing) > MAX_GAP:
                stopped = state["early_stop"]
                state.update(early_stop=None, early_stop_undone=stopped, pages_done=False, next_page=stopped + 1)
                state["note"] = (f"early stop at page {stopped} undone: {len(missing)} products available "
                                 f"last time are not in the pages read; reading the rest of the feed")
                return False
            source = "available last time"
        else:
            if state["sitemap"] is None:
                if state["shadow"] is None and not limit:
                    state["shadow"] = _shadow(shop, state)
                    print(f"   early-stop check: {shadow_text(state['shadow'])}", flush=True)
                state["sitemap"] = _sitemap_handles(shop, http)
            missing = [h for h in state["sitemap"] if h not in seen and h not in state["gone"]]
            if len(missing) > MAX_GAP:
                raise RuntimeError(f"{len(missing)} products in the sitemap are not in products.json "
                                   f"(more than {MAX_GAP}); check the feed")
            source = "from the sitemap"
        for i, handle in enumerate(missing):
            if budget == 0:
                state["note"] = f"{len(missing) - i} products {source} still to read"
                return False
            budget -= 1
            resp = http.get(f"{shop.base_url}/products/{handle}.js")
            if resp is None:
                state["gone"].append(handle)    # removed since the sitemap / last scrape
                continue
            _store(shop, state, seen, _from_js(resp.json()))
        state["note"] = _done_note(state)
        return True
    except BlockedError as exc:
        state["note"] = f"refused ({exc.summary()}); continues next session"
        return False
    finally:
        state["seen"] = sorted(seen)


def _done_note(state: dict) -> str:
    """Status note for a complete shop."""
    if state["early_stop"]:
        return (f"early stop after page {state['early_stop']}; all {len(state['reference'])} "
                f"products available last time accounted for")
    note = (f"{len(state['sitemap'])} products in the sitemap, all read"
            if state["sitemap"] else state["note"])
    if state["shadow"]:
        note += f"; early-stop check: {shadow_text(state['shadow'])}"
    return note


def _reference(state: dict, reference: Optional[Callable[[], List[str]]]) -> List[str]:
    """Handles the shop had available in its last scrape, loaded once and kept in the state.
    Empty when there is no earlier scrape or it cannot be read: then no early stop."""
    if state["reference"] is None:
        try:
            urls = reference() if reference else []
        except Exception as exc:                # noqa: BLE001 - no reference is safe: whole feed
            print(f"    no reference for the early stop: {type(exc).__name__}: {exc}", flush=True)
            urls = []
        state["reference"] = sorted({h for h in (handle_from_url(u) for u in urls) if h})
    return state["reference"]


def _empty_run(profile: list) -> int:
    """Feed pages without an available product at the end of the profile."""
    run = 0
    for entry in reversed(profile):
        if entry[2]:
            break
        run += 1
    return run


def _early_stop_now(shop, state: dict) -> bool:
    """End the feed read here? Only for a shop with early_stop_pages that has a reference
    and has not had its early stop undone this week."""
    pages = getattr(shop, "early_stop_pages", 0)
    return bool(pages and state["early_stop_undone"] is None and state["reference"]
                and _empty_run(state["profile"]) >= pages)


def _shadow(shop, state: dict) -> dict:
    """What the early stop would have done on this complete feed read (no requests).
    stop: page it would have ended on (None: it would not have); pages: pages read;
    checks: reference products it would have read on their own; undone: checks above
    MAX_GAP, so it would have read on and lost nothing; lost: available products in the
    unread pages that are not in the reference, so no check would have found them.
    Never raises: the check must not stop a scrape."""
    try:
        n = getattr(shop, "early_stop_pages", 0) or EARLY_STOP_PAGES
        profile = state["profile"]
        result = {"pages": len(profile), "stop": None}
        if not state["reference"]:
            result["no_reference"] = True
            return result
        run = 0
        for i, entry in enumerate(profile):
            if entry[1] < PAGE_SIZE:
                break                           # the last page: the read ended here anyway
            run = 0 if entry[2] else run + 1
            if run >= n:
                read, unread = profile[:i + 1], profile[i + 1:]
                reference = set(state["reference"])
                checks = len(reference - {h for e in read for h in e[3]})
                lost = sorted({h for e in unread for h in e[2]} - reference)
                result.update(stop=entry[0], checks=checks, undone=checks > MAX_GAP,
                              lost=[] if checks > MAX_GAP else lost)
                break
        return result
    except Exception as exc:                    # noqa: BLE001
        return {"error": f"{type(exc).__name__}: {exc}"}


def shadow_text(s: dict) -> str:
    """One line for the status report and the log."""
    if "error" in s:
        return f"failed ({s['error']})"
    if s.get("no_reference"):
        return f"no earlier scrape to check against ({s['pages']} pages read)"
    if s["stop"] is None:
        return f"would not stop early ({s['pages']} pages)"
    if s["undone"]:
        return (f"would stop at page {s['stop']} of {s['pages']}, then read on: {s['checks']} products "
                f"from last time not in those pages (more than {MAX_GAP})")
    lost = (f"{len(s['lost'])} LOST: {', '.join(s['lost'][:5])}{' ...' if len(s['lost']) > 5 else ''}"
            if s["lost"] else "0 lost")
    return (f"would stop at page {s['stop']} of {s['pages']} ({s['pages'] - s['stop']} pages saved, "
            f"{s['checks']} single reads), {lost}")


def _store(shop, state: dict, seen: set, item: dict) -> bool:
    """Record one catalogue product: its available rows replace any earlier read.
    True when the product has an available row."""
    handle = item.get("handle", "")
    seen.add(handle)
    rows = _rows(shop, item)
    if rows:
        state["rows"][handle] = [asdict(r) for r in rows]
    else:
        state["rows"].pop(handle, None)
    return bool(rows)

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
