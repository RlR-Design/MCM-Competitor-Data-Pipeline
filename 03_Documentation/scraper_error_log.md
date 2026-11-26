# Scraper Error Log

A record of scraper failures: what happened, the cause, what was done and what is still open.
Newest entry first. Shops are named shop_1..shop_10 (the key is in the local Manual, section 17).

| Status | Meaning |
|---|---|
| OPEN | Not solved; shops may still fail |
| MITIGATED | Partly handled; can happen again |
| RESOLVED | Fixed and confirmed by a successful scrape |

---

## 2026-11-26 · shop_2 sold out, 1 product left · OPEN

**What happened:** the 2026-11-22 weekly scrape read shop_2's whole feed (182 products, all
in the sitemap) and found 1 available product, against 28 the week before. 26 of last week's
28 are gone from the shop entirely; nearly everything left is tagged sold out. Not a scraper
fault: the owner checked the site on 11-26 and confirmed it. The shop may have been sold.

**Why it needed a rule:** with the default rule the run of 11-26 would not have logged the
sales. 1 product is below 0.7 x the baseline (~28), so sp_check_scrape_health marks the
scrape FAILED (LOW_PRODUCT_COUNT), and Gold ignores FAILED scrapes for delisting. Even then,
the default grace of 2 scrapes would have held them as PENDING_DELIST for another week.

**Done (2026-11-26, before the 19:00 upload):** at the owner's request, shop_2 has its own row in
ref_shop_rules: `delist_grace_scrapes = 1`, `min_count_ratio = 0`, everything else from the
default. The scrape is accepted and every product missing from it is SOLD (DELISTED), dated
this scrape. shop_2 had no earlier scrape gaps, so the rule changes no past events; its 2
products already PENDING_DELIST become SOLD as well.

**Open:** the owner is phoning the shop to find out what happened. Then:
- Shop closed or sold on: take it out of the shop list (`shops_config.py`) and decide what
  the warehouse keeps for it.
- Restocking under the same site: put the rule back to the default,
  `CALL sp_set_shop_rule('<shop_2>', NULL, 2, 0.7, NULL, NULL, NULL, NULL, NULL)`, because
  `min_count_ratio = 0` would also hide a real scraper failure for this shop.
- Meanwhile check shop_2 in each weekly status report.

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

**Checks 2026-11-16 (a few requests per shop, after the upload):**
- robots.txt on all 6 Shopify shops: no rule against `/products.json`, product pages or sitemaps.
- Product sitemaps answer normally on all 6 (even the shops refused the night before) and list
  every product including sold ones: shop_8 67, shop_2 210, shop_9 446, shop_1 564,
  shop_5 1,943, shop_6 4,701. These match the feed page counts (250 per page).
- shop_8's `/products.json` refused the very first request (429 `local_rate_limited`,
  Retry-After 60), 12 h after its last 2 pages: the feed limit is tighter and longer than
  "2 pages then 1 hour". No further test requests were made.

**Done 2026-11-16 (scraper 2.3.0, from the Sunday 2026-11-22 scrape): the week is spread out.**
- Sunday 21:00 starts the week (all shops); a session every 2 hours reads what is still open;
  Thursday 19:00 extracts and uploads (was Monday 07:00). The status report is read on Wednesday.
- Shopify: at most 2 feed requests per shop per session, stop at the first refusal (no waiting,
  no retries), continue from that page next session. Progress is saved per shop.
- Completeness: when the last page is read, the shop's product sitemap is compared with the
  products seen; products missing (pages shift when a shop deletes a product mid-week) are read
  one by one from `/products/<handle>.js`. Complete = every sitemap product read.
- Other shops: scraped whole on Sunday; a failure is retried in the next session (up to 4 attempts).
- A shop not complete at the upload is sent PARTIAL (products load, no delisting that week).
- Removed: long pauses and the second attempt within one run (the sessions replace them).
- Tested offline only (fake shops): page shift recovered via the sitemap, refusals resumed,
  a failing shop retried then given up, run script and watchdog decisions.

**Watch on 2026-11-22 to 11-26:** the first week on 2.3.0. Read the status report on Wednesday;
shop_6 needs about 19 feed pages, so 10+ sessions.

**Re-scrape of shop_9, shop_5, shop_6 for the 2026-11-15 week (2.3.0, scrape only, no upload):**
sessions every 2 hours from 2026-11-16 21:00, until all three are complete or 2026-11-22 18:00.
Output kept locally (`MCM_Rescrape_2026-11-16.csv`) to be added by hand.

| Session | shop_9 | shop_5 | shop_6 |
|---|---|---|---|
| 11-16 21:00 | refused | refused | refused |
| 11-16 23:00 | pages 1-2, complete (62 products; all 446 sitemap products read) | pages 1-2 (146) | pages 1-2 (99) |
| 11-17 01:00 | | pages 3-4 (169) | pages 3-4 (107) |
| 11-17 03:00, 05:00, 07:00 | | refused | refused |

**Finding (2026-11-17):** each shop allows about 4 feed pages (2 sessions), then refuses for
about 20 hours (the Sunday-night block lifted between 21:00 and 23:00 Monday). Refused requests
every 2 hours did not extend the block (refused at 21:00, through at 23:00), so the 2-hour gap
is kept: the limit is pages per day, and a longer gap would not let more pages through.
Expected: shop_5 (~8 pages) complete on 11-17 night; shop_6 (~19 pages) around 11-20/21.

**Open for the weekly schedule:** at ~4 pages a day shop_6 needs ~5 days, but Sunday 21:00 to
Thursday 19:00 is ~4 days, so shop_6 will likely be PARTIAL each week. Also, if this re-scrape
still reads shop_6 on Sunday 11-22, the weekly scrape may start blocked for it. To be decided
after one more night confirms the pattern (e.g. start shop_6 earlier in the week).

**Why the first weeks were fine (analysis 2026-11-17, from the run summaries and logs):**
- 10-25 and 11-01 (2.0.0, fake Chrome name, 2 s between requests): shop_6 read 20 pages in
  39 s, shop_5 9 pages in 17 s, no refusals. Now each shop allows ~4 pages, then ~20 h refused.
- First signs on 11-01: shop_2 had 3 refusals (429) and shop_1 one, never seen before.
  11-08: all 6 Shopify shops refused. Our code had not changed, and on 11-13 a plain request
  got through while the scraper was refused, so the change was on Shopify's side.
- Likely two causes that add up (Shopify does not publish how the limit works, so not proven):
  1. Shopify tightened its bot protection in early November (first refusals 11-01, full block
     of the fake-browser client 11-08).
  2. Our connection's standing: between 11-08 and 11-16 we sent probably hundreds of refused
     requests (up to 5 retries per page, second attempts, test runs 11-13/11-14, an hour of
     pause-and-retry on shop_5, a Sunday run that kept retrying refused pages). Rate limiters
     often give longer blocks to clients that keep coming back after a refusal. The limit is
     per shop (the next shop always answered normally).
- The honest name (11-14) ended the outright block but did not bring back the old allowance.

**How to tell which:** if it is our standing, weeks of polite scraping (few pages, stop at the
first refusal) should slowly loosen the limit. The session log shows how many pages each shop
allows before refusing; compare week by week, with no extra test requests. If it stays at ~4
pages a day, treat it as Shopify's new normal and settle a lasting route for shop_6.

**Re-scrape stopped and shop_6 rested (2026-11-20).** shop_6's allowance did not hold at
~4 pages a day: it decayed through the week, then stopped entirely.

| Day | Feed pages gained |
|---|---|
| 11-16 (from 21:00) | 2 |
| 11-17 | 8 |
| 11-18 | 4 |
| 11-19 | 1 (page 15, last page ever read, 07:10) |
| 11-20 | 0 (45 sessions in total, 38 refusals) |

Always 429, never 403, so it is throttling and not a ban. This decay during a week of
polite scraping (2 requests per session, stop at the first refusal) argues for cause 2
(our standing) over cause 1 (Shopify's new normal), and against the 11-17 reading that
refused requests do not extend the block: knocking ten times a day is the only thing we
do between successes.

**Done:** the re-scrape loop was killed 2026-11-20 14:51 (shop_9 and shop_5 were already
complete; their data is in the progress file, `--resume` still builds the CSV).
shop_6 is commented out of the local shop list until the **Sunday 2026-11-29** scrape, to
rest the limiter for a full week with no requests at all. While it is out of the list the
batch has no shop_6 rows, sp_check_scrape_health marks it SHOP_MISSING / FAILED, and Gold
ignores FAILED scrapes for delisting, so its products are not wrongly sold off.

**Found in the session data: the archive tail is dead weight for shop_6.** Available
products per page pair, this re-scrape:

| Pages | shop_5 (1,943 in sitemap) | shop_6 (4,701 in sitemap) |
|---|---|---|
| 1-2 | 146 | 99 |
| 3-4 | 169 | 107 |
| 5-6 | 192 | 107 |
| 7-8 | 203 (complete) | 107 |
| 9-15 | | 107 |

Every one of shop_6's available products sits in the first 4 pages; pages 5-15 (2,750 feed
entries) added nothing. For comparison, the full 20-page scrape of 10-25 found 92 available
products, fewer than the 107 the first 4 pages hold now, so pages 16-20 are very unlikely to
hold any. shop_5 is different: its tail still carries 34 of its 203, so this is per shop,
not a general rule, and an early stop must be adaptive (stop after N consecutive pages with
no available product) rather than a fixed page count.

**Done (scraper 2.4.0, 2026-11-22): the early stop, switched on per shop.**
- `Shop.early_stop_pages` (0 = off): the feed read ends after that many pages in a row without
  an available product. Set to 2 on shop_6's (commented-out) entry, so it is on when it returns.
- The sitemap check is replaced for such a shop by a reference check: every product it had
  available in its last scrape (newest earlier weekly or re-scrape CSV / raw file with rows for
  it) must be seen in the pages read, or is read on its own from `/products/<handle>.js`. A
  product that moved past the stop is found this way, not lost.
- More than MAX_GAP (25) of them unseen: the early stop is undone for the week and the rest of
  the feed is read, ending with the normal sitemap check. No reference (first scrape): whole feed.
- **Shadow check** on every other Shopify shop: it reads its whole feed exactly as before, and
  the status report adds what the early stop would have done ("would stop at page X of Y
  (N pages saved, K single reads), 0 lost", or "N LOST: handles"). No extra requests.

**Tested offline (no requests to any shop):**
- 18 unit tests (`04_Scraper/test_shopify_early_stop.py`): stop point, the empty run across
  sessions and through the progress file, products past the stop recovered, sold and deleted
  ones, the undo, no / unreadable reference, a refusal mid-check, upgrade of 2.3.0 state, the
  shadow arithmetic, the reference loader. Each of 4 deliberate bugs makes tests fail.
- Early stop off (all shops this week): 10,000 random feeds (refusals, sitemap gaps, deleted
  products) run through 2.3.0 and 2.4.0 give identical requests, products, state and notes.
- End to end through main.py: an archive-like shop gets the same products in 4 requests with
  the early stop instead of 9 without.

Not tested on live data before the week starts on purpose: reading the healthy shops' feeds on
2026-11-22 would have used up their allowance just before the Sunday 21:00 scrape. The shadow
check during the week is that test.

**Done (scraper, 2026-11-20):** a refusal now records its status, Retry-After and the
limiter's own words from the body (`local_rate_limited`, or an HTML block page's title)
instead of only "HTTP 429". `stop_on_blocked` used to raise before the branch that reads
Retry-After. No extra requests. This is what the week-by-week comparison below needs.

**Watch 2026-11-22 to 11-26:** the shadow check on the 5 healthy Shopify shops, in the status
report as each completes. "0 lost" on all of them supports the early stop; any "LOST" means
that shop keeps its whole feed read.

**Watch on 2026-11-29:** first scrape after the rest week. Compare shop_6's pages before the
first refusal against this week (8 -> 4 -> 1 -> 0). More than ~4 means the standing recovers
and politeness is the lever; still ~1 means the allowance is gone for good and shop_6 needs
the early stop, a monthly cadence, or a route that is not the feed.

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
