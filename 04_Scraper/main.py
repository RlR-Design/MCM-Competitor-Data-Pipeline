"""
===============================================================================
Script   : main.py
Layer    : Scraper
Purpose  : Weekly scrape of every shop in shops.py, in two stages:
             1. Scrape: fetch currently available products per shop and write
                <name>_raw.jsonl and <name>_run_summary.csv.
             2. Extract: fill category, makers, material, era, condition and
                dimensions with Claude (extraction.py), then write <name>.csv
                (17 columns, order of the data dictionary's Source Files tab).
           Stage 2 can be re-run later with --resume (e.g. after logging in to Claude).
When     : Weekly, by 05_Automation/mac/run_weekly_scrape.sh. Can be run by hand.
Requires : requests, beautifulsoup4; Claude Code logged in for stage 2.
Usage    : main.py --output <csv>                      scrape + extract
           main.py --output <csv> --resume             extract only, from the existing raw file
           main.py --output <csv> --scrape-only        stage 1 only
           main.py --output <csv> --shops "shop_1,shop_2" --limit 5   quick test
Exit     : 0 CSV written; 1 failed (all shops failed or bad arguments);
           2 scrape done but extraction pending (Claude unavailable): run --resume.
Warning  : Cleaning (NULLs, placeholders, trimming, coordinates) is done by the
           warehouse, not here. The CSV is loaded by column position.
===============================================================================
"""

import argparse
import csv
import json
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Dict, List

from common import HttpClient, RawProduct
from extraction import extract
from fetchers import FETCHERS
from scrape_run_summary import RunSummary, summary_path_for
from shops import load_shops, select_shops

SCRAPER_VERSION = "2.0.0"
MAX_PRICE = 999999.99           # warehouse quarantines prices above this (PRICE_OUT_OF_RANGE)
DEFAULT_CACHE = Path(__file__).resolve().parent.parent / "06_Datasets" / "extraction_cache.json"

# Products CSV columns, in load order.
COLUMNS = ["shop_name", "latitude", "longitude", "region", "city", "category", "title", "price",
           "description", "makers", "primary_material", "era", "condition", "dimensions", "url",
           "available", "timestamp"]


def raw_path_for(csv_path: str) -> str:
    return csv_path[:-4] + "_raw.jsonl"


def scrape(shops, limit, summary: RunSummary) -> List[RawProduct]:
    products: List[RawProduct] = []
    for shop in shops:
        print(f"\n== {shop.name} ({shop.platform})", flush=True)
        with summary.shop(shop.name) as run:
            http = HttpClient(run, delay=shop.delay)
            rows = FETCHERS[shop.platform](shop, http, run, limit)
            kept: Dict[str, RawProduct] = {}
            no_price = too_high = 0
            for p in rows:
                if not p.price:
                    no_price += 1
                elif float(p.price) > MAX_PRICE:
                    too_high += 1
                elif p.url not in kept:
                    kept[p.url] = p
            if not kept:
                raise RuntimeError("no available products found")
            run.products_found = len(kept)
            products.extend(kept.values())
            note = f", skipped {no_price} without price" if no_price else ""
            note += f", skipped {too_high} above R{MAX_PRICE:,.0f}" if too_high else ""
            print(f"   {len(kept)} available products{note}", flush=True)
        if run.status != "SUCCESS":
            print(f"   {run.status}: {run.error_message}", flush=True)
    return products


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
    ap.add_argument("--scrape-only", action="store_true", help="stop after writing the raw file and run summary")
    ap.add_argument("--shops", default="", help="comma-separated shop names (default: all)")
    ap.add_argument("--limit", type=int, default=None, help="max products per shop (testing)")
    ap.add_argument("--cache", default=str(DEFAULT_CACHE), help="extraction cache file")
    args = ap.parse_args()

    if not args.output.endswith(".csv"):
        print("--output must end in .csv", file=sys.stderr)
        return 1
    raw_path = raw_path_for(args.output)

    if args.resume:
        if not Path(raw_path).exists():
            print(f"Raw file not found: {raw_path}", file=sys.stderr)
            return 1
        with open(raw_path, encoding="utf-8") as f:
            products = [RawProduct(**json.loads(line)) for line in f if line.strip()]
        print(f"Loaded {len(products)} products from {raw_path}", flush=True)
    else:
        summary = RunSummary(scraper_version=SCRAPER_VERSION)
        products = scrape(select_shops(args.shops), args.limit, summary)
        summary.write(summary_path_for(args.output))
        if all(s.status == "FAILED" for s in summary.shops):
            # No raw file, so a later --resume cannot upload an empty batch.
            print("All shops failed.", file=sys.stderr)
            return 1
        with open(raw_path, "w", encoding="utf-8") as f:
            for p in products:
                f.write(json.dumps(asdict(p), ensure_ascii=False) + "\n")
        print(f"\nScrape done: {len(products)} products -> {raw_path}", flush=True)
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
