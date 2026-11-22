"""
===============================================================================
Script   : main.py
Layer    : Scraper
Purpose  : Weekly scrape of every shop in shops.py, in two stages:
             1. Scrape, in sessions spread over the week: Sunday 21:00 starts
                the week (--scrape-only), then a session every 2 hours
                (--continue) reads what is still open. Shopify shops read a
                couple of pages per session (Shopify refuses more) and continue
                where they stopped; other shops are scraped whole and retried
                when they fail. Every session rewrites, for the week:
                  <name>_progress.json    where each shop stands (the state)
                  <name>_raw.jsonl        products read so far
                  <name>_run_summary.csv  one row per shop (PARTIAL while open)
                  <name>_status.txt       readable status report (Wednesday check)
             2. Extract (Thursday, --resume): fill category, makers, material,
                era, condition and dimensions with Claude (extraction.py), then
                write <name>.csv (17 columns, order of the data dictionary's
                Source Files tab).
When     : By 05_Automation/mac/run_weekly_scrape.sh (launchd). Can be run by hand.
Requires : requests, beautifulsoup4; Claude Code logged in for stage 2.
Usage    : main.py --output <csv> --scrape-only        start the week (first session)
           main.py --output <csv> --continue           next session for the open shops
           main.py --output <csv> --continue --retry-failed   same, shops that gave up try again
           main.py --output <csv> --status             print the status report
           main.py --output <csv> --resume             extract from the raw file, write the CSV
           main.py --output <csv>                      one session + extract (by hand)
           main.py --output <csv> --shops "shop_1,shop_2" --limit 5   quick test
Exit     : 0 done; 1 failed (bad arguments, missing files, week already started);
           2 scrape saved but extraction pending (Claude unavailable): run --resume.
Warning  : Cleaning (NULLs, placeholders, trimming, coordinates) is done by the
           warehouse, not here. The CSV is loaded by column position.
===============================================================================
"""

import argparse
import csv
import json
import sys
import os
import re
import uuid
from datetime import datetime, timedelta
from dataclasses import asdict
from pathlib import Path
from typing import Dict, List

from common import HttpClient, RawProduct, utc_now
from extraction import extract
from fetchers import FETCHERS, shopify
from scrape_run_summary import RunSummary, ShopRun, summary_path_for
from shops import load_shops, select_shops

SCRAPER_VERSION = "2.4.0"
MAX_PRICE = 999999.99           # warehouse quarantines prices above this (PRICE_OUT_OF_RANGE)
DEFAULT_CACHE = Path(__file__).resolve().parent.parent / "06_Datasets" / "extraction_cache.json"

# Products CSV columns, in load order.
COLUMNS = ["shop_name", "latitude", "longitude", "region", "city", "category", "title", "price",
           "description", "makers", "primary_material", "era", "condition", "dimensions", "url",
           "available", "timestamp"]


def raw_path_for(csv_path: str) -> str:
    return csv_path[:-4] + "_raw.jsonl"


MAX_ATTEMPTS = 4                # failed attempts per shop per week before giving up (refusals do not count)
UPLOAD_DAY = 4                  # the week's upload: Thursday 19:00 (days after the Sunday scrape)


# Earlier outputs that tell which products a shop last had available (Shopify early stop).
EARLIER_OUTPUT = re.compile(r"^MCM_(?:All_products|Rescrape)_(\d{4}-\d{2}-\d{2})(?:\.csv|_raw\.jsonl)$")


def previous_urls(shop_name: str, csv_path: str) -> List[str]:
    """URLs the shop had available in its last scrape before this week: from the newest
    earlier products CSV or raw file (weekly or re-scrape) next to csv_path that has rows
    for the shop. Empty when there is none. The Shopify early stop checks these."""
    folder = Path(csv_path).resolve().parent
    week = Path(csv_path).stem.rsplit("_", 1)[-1]
    by_date: Dict[str, List[Path]] = {}
    for f in folder.iterdir():
        m = EARLIER_OUTPUT.match(f.name)
        if m and m.group(1) < week:
            by_date.setdefault(m.group(1), []).append(f)
    for date in sorted(by_date, reverse=True):
        urls = set()
        for f in by_date[date]:
            urls |= _shop_urls(f, shop_name)
        if urls:
            return sorted(urls)
    return []


def _shop_urls(path: Path, shop_name: str) -> set:
    """URLs of the shop's rows in a products CSV or raw file; empty if it cannot be read."""
    try:
        with open(path, encoding="utf-8", newline="") as f:
            if path.suffix == ".csv":
                return {r["url"] for r in csv.DictReader(f) if r.get("shop_name") == shop_name and r.get("url")}
            urls = set()
            for line in f:
                if line.strip():
                    r = json.loads(line)
                    if r.get("shop_name") == shop_name and r.get("url"):
                        urls.add(r["url"])
            return urls
    except (OSError, ValueError, KeyError, csv.Error) as exc:
        print(f"    reference: cannot read {path.name}: {exc}", flush=True)
        return set()


def progress_path_for(csv_path: str) -> str:
    return csv_path[:-4] + "_progress.json"


def status_path_for(csv_path: str) -> str:
    return csv_path[:-4] + "_status.txt"


def new_progress(csv_path: str) -> dict:
    return {"week": Path(csv_path).stem.rsplit("_", 1)[-1], "run_id": str(uuid.uuid4()),
            "scraper_version": SCRAPER_VERSION, "finished": False, "updated_at": "", "shops": {}}


def load_progress(csv_path: str) -> dict:
    with open(progress_path_for(csv_path), encoding="utf-8") as f:
        return json.load(f)


def save_progress(csv_path: str, progress: dict) -> None:
    progress["updated_at"] = datetime.now().strftime("%Y-%m-%d %H:%M")
    tmp = progress_path_for(csv_path) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(progress, f, ensure_ascii=False)
    os.replace(tmp, progress_path_for(csv_path))


def new_shop_state(shop) -> dict:
    st = {"status": "OPEN", "attempts": 0, "sessions": 0, "started_at": "", "finished_at": "",
          "pages_scraped": 0, "http_errors": 0, "retries": 0, "error_message": "", "products": []}
    if shop.platform == "shopify":
        st["shopify"] = shopify.new_state()
    return st


def finished(st: dict) -> bool:
    return st["status"] == "DONE" or st["attempts"] >= MAX_ATTEMPTS


def run_session(shops, progress: dict, csv_path: str, limit) -> None:
    """One pass over every shop that is not finished. Shopify shops read a few pages and
    continue in the next session; other shops are scraped whole, and retried in the next
    session when they fail (up to MAX_ATTEMPTS). Progress is saved after each shop."""
    for shop in shops:
        st = progress["shops"].setdefault(shop.name, new_shop_state(shop))
        if finished(st):
            continue
        print(f"\n== {shop.name} ({shop.platform})", flush=True)
        run = ShopRun(shop_name=shop.name)          # counters for this session
        http = HttpClient(run, delay=shop.delay)
        st["started_at"] = st["started_at"] or utc_now()
        st["sessions"] += 1
        try:
            if shop.platform == "shopify":
                done = shopify.session(shop, http, run, st["shopify"], limit,
                                       reference=lambda name=shop.name: previous_urls(name, csv_path))
                st["products"] = []                 # Shopify rows live in st["shopify"]
                print(f"   {st['shopify']['note']}", flush=True)
            else:
                st["attempts"] += 1
                st["products"] = [asdict(p) for p in FETCHERS[shop.platform](shop, http, run, limit)]
                done = run.status == "SUCCESS"
                if not done:
                    st["status"] = "PARTIAL"
                    st["error_message"] = run.error_message or ""
            if done:
                st["status"], st["error_message"], st["finished_at"] = "DONE", "", utc_now()
                print(f"   complete: {len(shop_rows(st)[0])} available products", flush=True)
            elif shop.platform == "shopify":
                st["status"] = "OPEN"
        except Exception as exc:                    # noqa: BLE001 - recorded, retried next session
            if shop.platform == "shopify":
                st["attempts"] += 1
            st["status"], st["error_message"] = "FAILED", f"{type(exc).__name__}: {exc}"
            print(f"   FAILED (attempt {st['attempts']} of {MAX_ATTEMPTS}): {st['error_message']}", flush=True)
        st["pages_scraped"] += run.pages_scraped
        st["http_errors"] += run.http_errors
        st["retries"] += run.retries
        progress["finished"] = all(finished(progress["shops"].get(s.name, {"status": "OPEN", "attempts": 0}))
                                   for s in shops)
        save_progress(csv_path, progress)


def shop_rows(st: dict):
    """The shop's products after the price checks, and a note on what was skipped."""
    raw = shopify.products(st["shopify"]) if "shopify" in st else [RawProduct(**p) for p in st["products"]]
    kept: Dict[str, RawProduct] = {}
    no_price = too_high = 0
    for p in raw:
        if not p.price:
            no_price += 1
        elif float(p.price) > MAX_PRICE:
            too_high += 1
        elif p.url not in kept:
            kept[p.url] = p
    note = f"skipped {no_price} without price" if no_price else ""
    note += (", " if note else "") + f"skipped {too_high} above R{MAX_PRICE:,.0f}" if too_high else ""
    return list(kept.values()), note


def shop_result(st: dict):
    """(status, message, products) for the run summary."""
    rows, _ = shop_rows(st)
    if st["status"] == "DONE":
        return ("SUCCESS", "", rows) if rows else ("FAILED", "no available products found", [])
    if st["status"] == "OPEN":
        note = st["shopify"]["note"] if "shopify" in st else ""
        msg = f"not finished: {st['pages_scraped']} pages read; {note}"
    else:
        msg = st["error_message"]
    return ("PARTIAL", msg, rows) if rows else ("FAILED", msg or "not scraped", [])


def write_outputs(shops, progress: dict, csv_path: str) -> List[RawProduct]:
    """Run summary, raw file (when there are products) and status report, from the progress."""
    summary = RunSummary(scraper_version=progress["scraper_version"], run_id=progress["run_id"])
    products: List[RawProduct] = []
    for shop in shops:
        st = progress["shops"].get(shop.name)
        if st is None:
            continue
        status, msg, rows = shop_result(st)
        summary.shops.append(ShopRun(
            shop_name=shop.name, started_at=st["started_at"], finished_at=st["finished_at"] or utc_now(),
            status=status, pages_scraped=st["pages_scraped"], products_found=len(rows),
            http_errors=st["http_errors"], retries=st["retries"], error_message=msg or None))
        products.extend(rows)
    summary.write(summary_path_for(csv_path))
    if products:
        tmp = raw_path_for(csv_path) + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            for p in products:
                f.write(json.dumps(asdict(p), ensure_ascii=False) + "\n")
        os.replace(tmp, raw_path_for(csv_path))
    with open(status_path_for(csv_path), "w", encoding="utf-8") as f:
        f.write(status_report(shops, progress))
    return products


def status_report(shops, progress: dict) -> str:
    """Plain-text weekly status, for the Wednesday check."""
    week = datetime.strptime(progress["week"], "%Y-%m-%d")
    upload = (week + timedelta(days=UPLOAD_DAY)).strftime("%A %Y-%m-%d") + " 19:00"
    lines, done, problems = [], 0, []
    for shop in shops:
        st = progress["shops"].get(shop.name)
        if st is None:
            lines.append((shop.name, "Not started", "", "", ""))
            problems.append(shop.name)
            continue
        rows, skipped = shop_rows(st)
        if st["status"] == "DONE":
            done += 1
            label = "Complete"
            detail = st["shopify"]["note"] if "shopify" in st else ""
            detail = "; ".join(x for x in (detail, skipped) if x)
        elif st["attempts"] >= MAX_ATTEMPTS:
            label, detail = "FAILED", f"gave up after {MAX_ATTEMPTS} attempts: {st['error_message']}"
            problems.append(shop.name)
        elif st["status"] in ("FAILED", "PARTIAL"):
            label = "Retrying"
            detail = f"attempt {st['attempts']} of {MAX_ATTEMPTS}: {st['error_message']}"
            problems.append(shop.name)
        else:
            label, detail = "In progress", st["shopify"]["note"] if "shopify" in st else ""
            problems.append(shop.name)
        lines.append((shop.name, label, str(len(rows)), str(st["pages_scraped"]), detail))
    head = (f"MCM weekly scrape, week of {progress['week']}  (updated {progress['updated_at']})\n"
            f"Result: {done} of {len(shops)} shops complete."
            + (f" Not complete: {', '.join(problems)}." if problems else " Ready for the upload.") + "\n"
            f"Upload: {upload}.\n\n")
    w = max(len(r[0]) for r in lines)
    table = f"{'Shop':<{w}}  {'Status':<11}  {'Products':>8}  {'Pages':>5}  Detail\n"
    table += "".join(f"{n:<{w}}  {s:<11}  {p:>8}  {g:>5}  {d}\n" for n, s, p, g, d in lines)
    foot = ("\nIn progress / Retrying: scraped again every 2 hours until the Thursday upload.\n"
            "FAILED: needs a look before the upload (log: 06_Datasets/logs/weekly_scrape_<date>.log).\n"
            "A shop not complete at the upload is sent as PARTIAL or FAILED; the warehouse then\n"
            "keeps its products as they were (no delisting) for that week.\n")
    return head + table + foot


def write_products(path: str, products: List[RawProduct], fields: Dict[str, Dict[str, str]]) -> None:
    shops = {s.name: s for s in load_shops()}
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, quoting=csv.QUOTE_ALL)
        writer.writerow(COLUMNS)
        for p in products:
            shop = shops[p.shop_name]
            x = fields.get(p.url, {})
            writer.writerow([
                p.shop_name, shop.latitude, shop.longitude, shop.region, shop.city,
                x.get("category", ""), p.title, p.price, p.description,
                x.get("makers", ""), x.get("primary_material", ""), x.get("era", ""),
                x.get("condition", ""), x.get("dimensions", ""),
                p.url, "true", p.scraped_at,
            ])


def main() -> int:
    ap = argparse.ArgumentParser(description="Scrape the shops and write the products CSV.")
    ap.add_argument("--output", required=True, help="products CSV path, e.g. MCM_All_products_2026-10-26.csv")
    ap.add_argument("--resume", action="store_true", help="skip scraping; extract from the existing raw file")
    ap.add_argument("--scrape-only", action="store_true",
                    help="start the week: first session, no extraction (Sunday)")
    ap.add_argument("--continue", dest="cont", action="store_true",
                    help="next session for the shops not finished yet (no extraction)")
    ap.add_argument("--retry-failed", action="store_true",
                    help="with --continue: give shops that gave up a fresh set of attempts (after a fix)")
    ap.add_argument("--status", action="store_true", help="print the week's status report")
    ap.add_argument("--shops", default="", help="comma-separated shop names (default: all)")
    ap.add_argument("--limit", type=int, default=None, help="max products per shop (testing)")
    ap.add_argument("--cache", default=str(DEFAULT_CACHE), help="extraction cache file")
    args = ap.parse_args()

    if not args.output.endswith(".csv"):
        print("--output must end in .csv", file=sys.stderr)
        return 1
    raw_path = raw_path_for(args.output)
    has_progress = Path(progress_path_for(args.output)).exists()

    if args.status or args.cont:
        if not has_progress:
            print(f"No progress file: {progress_path_for(args.output)}", file=sys.stderr)
            return 1
        progress = load_progress(args.output)
        shops = select_shops(args.shops)
        if args.cont and args.retry_failed:
            for st in progress["shops"].values():
                if st["status"] != "DONE":
                    st["attempts"] = 0
        if args.cont:
            run_session(shops, progress, args.output, args.limit)
        write_outputs(shops, progress, args.output)
        print("\n" + status_report(shops, progress), flush=True)
        return 0

    if args.resume:
        if not Path(raw_path).exists():
            print(f"Raw file not found: {raw_path}", file=sys.stderr)
            return 1
        with open(raw_path, encoding="utf-8") as f:
            products = [RawProduct(**json.loads(line)) for line in f if line.strip()]
        print(f"Loaded {len(products)} products from {raw_path}", flush=True)
    else:
        if has_progress:
            print(f"This week has started already ({progress_path_for(args.output)}); "
                  f"use --continue", file=sys.stderr)
            return 1
        shops = select_shops(args.shops)
        progress = new_progress(args.output)
        run_session(shops, progress, args.output, args.limit)
        products = write_outputs(shops, progress, args.output)
        print("\n" + status_report(shops, progress), flush=True)
        if not products:
            # No raw file, so a later --resume cannot upload an empty batch.
            print("No products yet (all shops failed or still to be read).", file=sys.stderr)
            return 0 if args.scrape_only else 1
        print(f"Scrape session done: {len(products)} products so far -> {raw_path}", flush=True)
    if args.scrape_only:
        return 0

    fields, pending = extract(products, Path(args.cache))
    if pending:
        print(f"\nExtraction incomplete: {len(pending)} products pending. "
              f"Log in to Claude, then run again with --resume.", file=sys.stderr)
        return 2
    write_products(args.output, products, fields)
    print(f"Done: {len(products)} products -> {args.output}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
