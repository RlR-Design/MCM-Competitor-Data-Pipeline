# Scraper Error Log

A record of scraper failures: what happened, the cause, what was done and what is still open.
Newest entry first. Shops are named shop_1..shop_10 (the key is in the local Manual, section 17).

| Status | Meaning |
|---|---|
| OPEN | Not solved; shops may still fail |
| MITIGATED | Partly handled; can happen again |
| RESOLVED | Fixed and confirmed by a successful scrape |

---

## 2026-11-08 · Shopify shops blocked (429 / 403) · MITIGATED

**Root cause found 2026-11-14:** the scraper sent a *Chrome browser* User-Agent from a Python
client. Shopify treats a fake browser name as a bot in disguise and answers 429 / 403.
With an honest name (`MCM-Competitor-Data-Pipeline (market research; +repo URL)`) the same
request got 200 on all 6 Shopify shops. The 4 other shops also accept the honest name.
robots.txt on these shops does not disallow `/products.json`.

**Done (scraper 2.2.0, 2026-11-14):**
- Honest User-Agent for all shops (no browser disguise).
- Shopify: 20 s between page requests (was 3 s).
- Shopify: when a page stays rate limited after 3 retries, pause 15 min and continue from
  that page (up to 4 pauses) instead of failing or starting over from page 1.

**Re-scrape 2026-11-14 (2.2.0, scrape only, no upload):**
- shop_8, shop_9, shop_2, shop_1: SUCCESS first try, no retries (21 + 62 + 28 + 13 = 124 products).
- shop_5, shop_6: still 429 part-way (big catalogues: ~9 and ~20 pages incl. sold items),
  after many test requests that day. Re-run with pause-and-continue: _result pending_.

Earlier findings below (the "connection fingerprint" explanation of 2026-11-13 was incomplete:
the fake browser name was the trigger).

**Run:** weekly scrape 2026-11-08 21:00 (scraper 2.0.0), uploaded 2026-11-09 07:02.

**Affected:** all 6 Shopify shops: shop_1, shop_2, shop_5, shop_6, shop_8 (client), shop_9.
The 4 shops on other platforms (WooCommerce, Pagelayer, Wix) scraped normally: 513 products uploaded instead of ~1,000.

| Shop | Error |
|---|---|
| shop_8 | HTTP 429 after 4 retries |
| shop_9 | HTTP 429 after 4 retries (page 1 loaded, page 2 failed) |
| shop_5 | HTTP 429 after 4 retries |
| shop_6 | HTTP 429 after 4 retries (2 pages loaded) |
| shop_2 | 429 three times, then 403 Forbidden |
| shop_1 | 403 Forbidden on the first request |

**Impact on the warehouse:** none. The run summary marked the 6 shops FAILED, and Gold ignores
FAILED scrapes for delisting, so no products were wrongly marked sold or delisted.
The week simply has no new prices for these shops.

**Cause (found 2026-11-13):** Shopify (through Cloudflare) now blocks the scraper's Python HTTP
client itself. At the same moment, a plain `curl` request to the same URL got 200 while Python
got 429, even with identical headers. Python and its libraries did not change since 2026-10-24,
so the change is on Shopify's side (bot protection based on the client's connection fingerprint).
On 2026-11-01 the same code scraped all 6 shops without problems.

**Done (scraper 2.1.0, 2026-11-13):**
- Rate limits (429) wait longer: Retry-After, or 30, 60, 120, 240 s (max 300 s).
- Shopify 403 is retried like a rate limit instead of failing at once.
- 3 s between Shopify requests (was 2 s); 5 retries for Shopify.
- Shops that fail get a second attempt at the end of the run, at least 10 minutes later.
  The second attempt replaces the first in the run summary.

These handle short rate limits. They do not get past a block of the Python client.

**Not adopted:** a library that disguises the scraper as a Chrome browser (curl_cffi) gets
through, but it deliberately works around the block the platform set up. Not used.

**Open:**
- [ ] Re-scrape the 6 shops once the block lifts (attempt 2026-11-13: see below).
- [ ] Decide a lasting route for Shopify shops (permission / data feed from the shops, or accept gaps).

**Attempts:**
- 2026-11-13 (~55 min run): re-scrape of the 6 shops with 2.1.0, scrape only (no upload).
  shop_9 got through on its second attempt (62 products, after 7 rate-limit waits).
  shop_1, shop_2, shop_5, shop_6, shop_8 still answered 429 on both attempts (5 retries each, up to 300 s waits).
  Not uploaded: a batch of 1 shop would count the other 9 as missing. Block still in place.
