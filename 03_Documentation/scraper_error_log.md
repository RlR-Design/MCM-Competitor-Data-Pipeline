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
  after many test requests that day. Re-run with pause-and-continue: shop_5 stayed limited on
  pages 3-4 for ~1 hour (4 pauses); stopped by hand so the limit can clear before Sunday.
  shop_6 not reached. Both left to the Sunday 2026-11-15 run.

**Re-scrape data (not uploaded to the pipeline):** the 4 successful shops were extracted with
the normal step (114 from cache, 10 via Claude) and saved locally in 06_Datasets/ in the
weekly format (17 columns), to be added to the 2026-11-08 data by hand:
- `MCM_Rescrape_2026-11-14.csv` (124 products: shop_9 62, shop_2 28, shop_8 21, shop_1 13)
- `MCM_Rescrape_2026-11-14_run_summary.csv` (4 shops, all SUCCESS)
- `MCM_Rescrape_2026-11-14_raw.jsonl` (raw scrape)

**Pre-run checks for Sunday 2026-11-15 (done 2026-11-14):**
- Non-Shopify shops (shop_3, shop_4, shop_7, shop_10) with the honest name, 3 products each:
  all SUCCESS; titles, prices and descriptions match the 2026-11-08 scrape (only real shop edits differ).
- Second attempt and time limit tested offline with fake shops: a shop that fails once is
  recovered; a shop that keeps failing ends FAILED without stopping the run.
- New safeguard: no second attempts after 5 h of scraping, so the Sunday 21:00 scrape ends
  before the Monday 07:00 upload.
- launchd jobs loaded (Sun 21:00 scrape, Mon 07:00 upload), wake set for Sun 20:55, run script syntax OK.
- No Shopify requests after 2026-11-14 ~16:00, so the rate limit can clear before the run.

**Watch on Sunday 2026-11-15:** shop_5 and shop_6 may still hit the limit. With 2.2.0 they
pause and continue instead of failing at once; check their rows in the run summary on Monday.

**Weekly run 2026-11-15 (2.2.0, 21:00 to 02:40):** 7 of 10 shops SUCCESS, 579 products.

| Shop | Status | Pages | Products | Note |
|---|---|---|---|---|
| shop_8 | SUCCESS | 2 | 21 | no retries |
| shop_9 | FAILED | 2 | 0 | page 3 (the empty end page) refused through 4 pauses (~80 min) |
| shop_5 | FAILED | 2 | 0 | page 3 refused through 4 pauses |
| shop_6 | FAILED | 2 | 0 | page 3 refused through 4 pauses |
| shop_2 | SUCCESS | 2 | 28 | no retries |
| shop_1 | SUCCESS | 4 | 13 | got through after 3 pauses (~45 min) |
| shop_7, shop_4, shop_3, shop_10 | SUCCESS | | 132, 130, 32, 223 | not Shopify, no problems |

No second attempts: the 3 failed shops ran the scrape past the 5 h limit.
FAILED shops are ignored for delisting, so the Monday upload does no harm; those 3 shops
simply have no new data this week.

**Finding:** each Shopify shop now allows about 2 page requests, then refuses for an hour or
more (per shop: the next shop answered normally straight after). The big catalogues
(shop_5 ~8 pages, shop_6 ~19 pages incl. sold items) cannot be read in one night at this rate.

**Done 2026-11-16:** the Shopify fetcher stops after a page that is shorter than page 1
(it no longer requests the empty end page). shop_9 needs 2 requests instead of 3 and
would have succeeded this week; shop_1 needs 3 instead of 4. Tested offline only.

**Open:** a weekly schedule that reads the big Shopify shops completely under this limit
(proposal: a few pages per shop per session, spread over the week; not built yet).

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
