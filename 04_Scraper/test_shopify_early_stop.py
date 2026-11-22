"""
===============================================================================
Script   : test_shopify_early_stop.py
Layer    : Scraper (tests)
Purpose  : Offline tests for the Shopify early stop, the shadow check and the
           reference loader (scraper 2.4.0). A fake shop serves the feed, the
           sitemap and single products; no network. Between sessions the
           state goes through JSON, as it does in the week's progress file.
Usage    : cd 04_Scraper && ../.venv/bin/python -m unittest test_shopify_early_stop -v
===============================================================================
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import BlockedError                     # noqa: E402
from fetchers import shopify                        # noqa: E402
from shops import Shop                              # noqa: E402
import main                                         # noqa: E402

BASE = "https://shop.example"


def product(handle: str, available: bool) -> dict:
    return {"handle": handle, "title": handle, "body_html": "", "product_type": "Chair", "tags": [],
            "vendor": "", "variants": [{"id": 1, "title": "Default Title", "available": available,
                                        "price": "100.00", "compare_at_price": None}]}


def feed(*pages):
    """Catalogue in feed order. Each page is a string, one letter per product:
    'a' available, 's' sold. Handles are p<page>_<n>."""
    return [product(f"p{i}_{j}", c == "a") for i, page in enumerate(pages, 1) for j, c in enumerate(page)]


class FakeResp:
    def __init__(self, data=None, text=""):
        self._data, self.text = data, text

    def json(self):
        return self._data


class FakeHttp:
    """Serves a catalogue like a Shopify shop. refuse: request numbers (1-based) to refuse."""

    def __init__(self, catalogue, refuse=()):
        self.catalogue = catalogue
        self.by_handle = {p["handle"]: p for p in catalogue}
        self.refuse = set(refuse)
        self.requests = []
        self.delay, self.blocked_status, self.stop_on_blocked = 1.0, set(), False

    def get(self, url, params=None):
        self.requests.append(url + (f"?page={params['page']}" if params else ""))
        if len(self.requests) in self.refuse:
            raise BlockedError(f"{url}: HTTP 429", status=429)
        if url.endswith("/products.json"):
            size = shopify.PAGE_SIZE
            page = params["page"]
            return FakeResp({"products": self.catalogue[(page - 1) * size:page * size]})
        if url.endswith("/sitemap.xml"):
            return FakeResp(text=f"<loc>{BASE}/sitemap_products_1.xml?from=1&amp;to=9</loc>")
        if "sitemap_products" in url:
            return FakeResp(text="".join(f"<loc>{BASE}/products/{h}</loc>" for h in self.by_handle))
        if url.endswith(".js"):
            p = self.by_handle.get(url.rsplit("/", 1)[1][:-3])
            if p is None:
                return None
            v = p["variants"][0]
            return FakeResp({"handle": p["handle"], "title": p["title"], "description": "", "type": "Chair",
                             "tags": [], "vendor": "", "variants": [{"id": v["id"], "title": v["title"],
                                                                     "available": v["available"],
                                                                     "price": 10000, "compare_at_price": None}]})
        raise AssertionError(f"unexpected request {url}")


class FakeRun:
    pages_scraped = 0


def shop(early_stop_pages=0):
    return Shop("Test", "shopify", BASE, "Gauteng", "Pretoria", 0.0, 0.0, early_stop_pages=early_stop_pages)


def urls(*handles):
    return [f"{BASE}/products/{h}" for h in handles]


def scrape(the_shop, http, reference=(), state=None, max_sessions=40, reference_fn=None):
    """Sessions until the shop is complete. Returns (state, sessions)."""
    state = state if state is not None else shopify.new_state()
    ref = reference_fn or (lambda: list(reference))
    for n in range(1, max_sessions + 1):
        state = json.loads(json.dumps(state))                 # as through the progress file
        with contextlib.redirect_stdout(io.StringIO()):
            done = shopify.session(the_shop, http, FakeRun(), state, reference=ref)
        if done:
            return state, n
    raise AssertionError(f"not complete after {max_sessions} sessions; note: {state['note']}")


def available(state):
    return sorted(state["rows"])


class EarlyStopTests(unittest.TestCase):

    def setUp(self):
        self._page_size, self._max_gap = shopify.PAGE_SIZE, shopify.MAX_GAP
        shopify.PAGE_SIZE = 4

    def tearDown(self):
        shopify.PAGE_SIZE, shopify.MAX_GAP = self._page_size, self._max_gap

    # A shop like shop_6: the live stock in the first pages, then a long sold archive.
    ARCHIVE = ("aaas", "aass", "ssss", "ssss", "ssss", "ssss", "ssss", "ss")

    def test_early_stop_ends_feed_read_after_empty_pages(self):
        cat = feed(*self.ARCHIVE)
        live = [p["handle"] for p in cat if p["variants"][0]["available"]]
        http = FakeHttp(cat)
        state, _ = scrape(shop(2), http, urls(*live))
        self.assertEqual(state["early_stop"], 4)
        self.assertEqual(http.requests, [f"{BASE}/products.json?page={n}" for n in (1, 2, 3, 4)])
        self.assertEqual(available(state), sorted(live))
        self.assertIn("early stop after page 4", state["note"])

    def test_empty_run_counts_across_sessions(self):
        cat = feed("aaaa", "aaaa", "aaaa", "ssss", "ssss", "ssss", "ss")
        http = FakeHttp(cat)
        state, sessions = scrape(shop(2), http, urls("p1_0"))
        self.assertEqual(state["early_stop"], 5)                 # pages 4 (session 2) and 5 (session 3)
        self.assertEqual(sessions, 3)

    def test_empty_run_resets_on_a_page_with_stock(self):
        cat = feed("assa", "ssss", "assa", "ssss", "assa", "ss")
        http = FakeHttp(cat)
        state, _ = scrape(shop(2), http, urls("p1_0"))
        self.assertIsNone(state["early_stop"])
        self.assertIn(f"{BASE}/sitemap.xml", http.requests)       # whole feed, then the sitemap check

    def test_reference_products_beyond_the_stop_are_read_on_their_own(self):
        cat = feed("aaas", "ssss", "ssss", "ssss", "ssss", "sasa", "ss")
        cat[22]["variants"][0]["available"] = False             # p6_2: sold since the last scrape
        http = FakeHttp(cat)
        ref = urls("p1_0", "p6_1", "p6_2", "deleted-since")      # p6_1 moved past the stop, still live
        state, _ = scrape(shop(2), http, ref)
        self.assertEqual(state["early_stop"], 3)
        singles = [r for r in http.requests if r.endswith(".js")]
        self.assertEqual(sorted(singles), sorted(f"{BASE}/products/{h}.js"
                                                 for h in ("p6_1", "p6_2", "deleted-since")))
        self.assertIn("p6_1", state["rows"])                     # recovered, not lost
        self.assertNotIn("p6_2", state["rows"])                  # sold: no row
        self.assertEqual(state["gone"], ["deleted-since"])
        self.assertNotIn(f"{BASE}/sitemap.xml", http.requests)

    def test_too_many_unseen_reference_products_undo_the_early_stop(self):
        shopify.MAX_GAP = 2
        cat = feed("aass", "ssss", "ssss", "aaaa", "ss")
        http = FakeHttp(cat)
        state, _ = scrape(shop(2), http, urls("p1_0", "p4_0", "p4_1", "p4_2"))
        self.assertIsNone(state["early_stop"])
        self.assertEqual(state["early_stop_undone"], 3)
        self.assertEqual(available(state), sorted(["p1_0", "p1_1", "p4_0", "p4_1", "p4_2", "p4_3"]))
        pages = [r for r in http.requests if "products.json" in r]
        self.assertEqual(pages, [f"{BASE}/products.json?page={n}" for n in (1, 2, 3, 4, 5)])
        self.assertIn(f"{BASE}/sitemap.xml", http.requests)       # ends with the normal check

    def test_no_reference_reads_the_whole_feed(self):
        http = FakeHttp(feed(*self.ARCHIVE))
        state, _ = scrape(shop(2), http, reference=())
        self.assertIsNone(state["early_stop"])
        self.assertEqual(len([r for r in http.requests if "products.json" in r]), len(self.ARCHIVE))

    def test_a_failing_reference_is_safe(self):
        def broken():
            raise OSError("disk gone")
        http = FakeHttp(feed(*self.ARCHIVE))
        state, _ = scrape(shop(2), http, reference_fn=broken)
        self.assertIsNone(state["early_stop"])
        self.assertEqual(state["reference"], [])
        self.assertIn(f"{BASE}/sitemap.xml", http.requests)

    def test_refusal_during_the_reference_check_continues_next_session(self):
        cat = feed("aaas", "ssss", "ssss", "sass", "ss")
        http = FakeHttp(cat, refuse={4})                          # 1-3: pages; 4: the single read
        state, sessions = scrape(shop(2), http, urls("p1_0", "p4_1"))
        self.assertEqual(state["early_stop"], 3)
        self.assertIn("p4_1", state["rows"])
        self.assertGreater(sessions, 2)

    def test_state_from_an_earlier_version_is_upgraded(self):
        old = {"next_page": 2, "pages_done": False, "seen": ["p1_0"], "rows": {}, "sitemap": None,
               "gone": [], "note": "continues at page 2"}               # 2.3.0 shape
        http = FakeHttp(feed("asss", "ssss", "ss"))
        state, _ = scrape(shop(0), http, urls("p1_0"), state=old)
        for key in ("profile", "reference", "early_stop", "early_stop_undone", "shadow"):
            self.assertIn(key, state)


class ShadowCheckTests(unittest.TestCase):
    """A shop without early_stop_pages reads its whole feed; the shadow check says what
    an early stop would have done."""

    def setUp(self):
        self._page_size, self._max_gap = shopify.PAGE_SIZE, shopify.MAX_GAP
        shopify.PAGE_SIZE = 4

    def tearDown(self):
        shopify.PAGE_SIZE, shopify.MAX_GAP = self._page_size, self._max_gap

    def test_archive_shop_would_stop_early_and_lose_nothing(self):
        cat = feed(*EarlyStopTests.ARCHIVE)
        live = [p["handle"] for p in cat if p["variants"][0]["available"]]
        http = FakeHttp(cat)
        state, _ = scrape(shop(0), http, urls(*live))
        s = state["shadow"]
        self.assertEqual((s["stop"], s["pages"], s["checks"], s["lost"], s["undone"]), (4, 8, 0, [], False))
        self.assertIn("would stop at page 4 of 8 (4 pages saved, 0 single reads), 0 lost", state["note"])
        self.assertIn(f"{BASE}/sitemap.xml", http.requests)       # behaviour unchanged

    def test_stock_in_the_tail_that_is_new_is_reported_lost(self):
        cat = feed("aass", "ssss", "ssss", "saas", "ss")          # p4_1, p4_2 new this week
        state, _ = scrape(shop(0), FakeHttp(cat), urls("p1_0", "p1_1"))
        s = state["shadow"]
        self.assertEqual(s["stop"], 3)
        self.assertEqual(s["lost"], ["p4_1", "p4_2"])
        self.assertIn("2 LOST: p4_1, p4_2", state["note"])

    def test_stock_in_the_tail_from_last_time_counts_as_recovered(self):
        cat = feed("aass", "ssss", "ssss", "saas", "ss")
        state, _ = scrape(shop(0), FakeHttp(cat), urls("p1_0", "p1_1", "p4_1", "p4_2"))
        s = state["shadow"]
        self.assertEqual((s["checks"], s["lost"]), (2, []))

    def test_too_many_checks_would_undo_and_lose_nothing(self):
        shopify.MAX_GAP = 1
        cat = feed("aass", "ssss", "ssss", "saas", "ss")
        state, _ = scrape(shop(0), FakeHttp(cat), urls("p1_0", "p4_1", "p4_2"))
        s = state["shadow"]
        self.assertTrue(s["undone"])
        self.assertEqual(s["lost"], [])
        self.assertIn("then read on", state["note"])

    def test_shop_with_stock_throughout_would_not_stop(self):
        state, _ = scrape(shop(0), FakeHttp(feed("aass", "sass", "ssas", "a")), urls("p1_0"))
        self.assertIsNone(state["shadow"]["stop"])
        self.assertIn("would not stop early (4 pages)", state["note"])

    def test_no_reference_says_so(self):
        state, _ = scrape(shop(0), FakeHttp(feed("aass", "ssss", "ssss", "ss")), reference=())
        self.assertTrue(state["shadow"]["no_reference"])
        self.assertIn("no earlier scrape to check against", state["note"])

    def test_the_check_never_breaks_a_scrape(self):
        st = shopify.new_state()
        st["reference"], st["profile"] = ["x"], "not a list of pages"
        self.assertIn("error", shopify._shadow(shop(0), st))


class ReferenceTests(unittest.TestCase):

    def test_handle_from_url(self):
        self.assertEqual(shopify.handle_from_url(f"{BASE}/products/teak-chair"), "teak-chair")
        self.assertEqual(shopify.handle_from_url(f"{BASE}/products/teak-chair?variant=42"), "teak-chair")
        self.assertEqual(shopify.handle_from_url(f"{BASE}/products/kiaat%20table/"), "kiaat table")
        self.assertEqual(shopify.handle_from_url(f"{BASE}/collections/all"), "")

    def test_previous_urls_takes_the_newest_earlier_scrape_with_the_shop(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)

            def csv_file(name, rows):
                lines = ['"shop_name","url"'] + [f'"{s}","{u}"' for s, u in rows]
                (d / name).write_text("\n".join(lines) + "\n", encoding="utf-8")

            csv_file("MCM_All_products_2026-11-01.csv", [("A", "u/a-old"), ("B", "u/b-old")])
            csv_file("MCM_All_products_2026-11-15.csv", [("B", "u/b-new")])        # no A this week
            csv_file("MCM_All_products_2026-11-15_run_summary.csv", [("A", "u/summary")])   # not products
            (d / "MCM_Rescrape_2026-11-16_raw.jsonl").write_text(
                json.dumps({"shop_name": "A", "url": "u/a-rescrape"}) + "\n\n", encoding="utf-8")
            csv_file("MCM_All_products_2026-11-22.csv", [("A", "u/a-this-week")])  # this week: not earlier
            (d / "MCM_Rescrape_2026-11-20_raw.jsonl").write_text("{not json", encoding="utf-8")
            this_week = str(d / "MCM_All_products_2026-11-22.csv")

            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main.previous_urls("A", this_week), ["u/a-rescrape"])
                self.assertEqual(main.previous_urls("B", this_week), ["u/b-new"])
                self.assertEqual(main.previous_urls("C", this_week), [])
                self.assertEqual(main.previous_urls("A", str(d / "MCM_All_products_2026-11-08.csv")),
                                 ["u/a-old"])


if __name__ == "__main__":
    unittest.main()
