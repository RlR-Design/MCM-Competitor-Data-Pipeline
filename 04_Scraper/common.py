"""
===============================================================================
Script   : common.py
Layer    : Scraper
Purpose  : Shared pieces for the fetchers: the raw product record, the HTTP
           client (delay, retries, counters) and text / price helpers.
Requires : requests, beautifulsoup4
===============================================================================
"""

import html
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Dict, Optional, Sequence

import requests
from bs4 import BeautifulSoup

USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")


def utc_now() -> str:
    """Current UTC time, YYYY-MM-DD HH:MM:SS."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


@dataclass
class RawProduct:
    """One available product as fetched, before extraction."""
    shop_name: str
    url: str
    title: str
    price: str                      # plain number, e.g. "10290.00"
    scraped_at: str
    description: str = ""
    source_category: str = ""       # the shop's own category, a hint for Claude
    hints: Dict[str, str] = field(default_factory=dict)   # vendor, tags, maker, compare_at_price, ...


class FetchError(Exception):
    """A request still failed after all retries."""


class HttpClient:
    """requests session with a polite delay, retries with backoff and counters for the run summary."""

    RETRY_STATUS = {429, 500, 502, 503, 504}

    def __init__(self, run, delay: float = 1.0, retries: int = 4, timeout: int = 30):
        self.run = run              # ShopRun: http_errors and retries are counted on it
        self.delay = delay
        self.retries = retries
        self.timeout = timeout
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": USER_AGENT})
        self._last = 0.0

    def get(self, url: str, params: Optional[dict] = None) -> Optional[requests.Response]:
        """Response for a 2xx, None for a 404. Raises FetchError when retries are exhausted.
        Rate limits (429) wait for Retry-After, or 15, 30, 60, 120 s; other errors 2, 4, 8, 16 s."""
        for attempt in range(self.retries + 1):
            backoff = 2 ** (attempt + 1)
            wait = self.delay - (time.monotonic() - self._last)
            if wait > 0:
                time.sleep(wait)
            self._last = time.monotonic()
            try:
                resp = self.session.get(url, params=params, timeout=self.timeout)
                if resp.status_code == 404:
                    return None
                if resp.status_code not in self.RETRY_STATUS:
                    resp.raise_for_status()
                    return resp
                problem = f"HTTP {resp.status_code}"
                if resp.status_code == 429:
                    retry_after = resp.headers.get("Retry-After", "")
                    backoff = max(float(retry_after) if retry_after.replace(".", "", 1).isdigit() else 0,
                                  15 * 2 ** attempt)
            except requests.HTTPError as exc:
                self.run.http_errors += 1
                raise FetchError(f"{url}: {exc}") from exc
            except requests.RequestException as exc:
                problem = type(exc).__name__
            if attempt == self.retries:
                self.run.http_errors += 1
                raise FetchError(f"{url}: {problem} after {self.retries} retries")
            self.run.retries += 1
            print(f"    {problem}, retrying in {backoff:.0f}s", flush=True)
            time.sleep(backoff)
        raise AssertionError("unreachable")


def html_to_text(markup: str) -> str:
    """Readable text from an HTML fragment: one line per block, no blank runs."""
    if not markup:
        return ""
    soup = BeautifulSoup(markup, "html.parser")
    for tag in soup.find_all(["script", "style", "form"]):
        tag.decompose()
    for br in soup.find_all("br"):
        br.replace_with("\n")
    text = soup.get_text("\n")
    lines = [re.sub(r"[ \t\xa0]+", " ", line).strip() for line in text.splitlines()]
    return "\n".join(line for line in lines if line)


def cut_boilerplate(text: str, markers: Sequence[str]) -> str:
    """Text before the first boilerplate marker."""
    if not markers:
        return text.strip()
    return re.split("|".join(markers), text, maxsplit=1, flags=re.IGNORECASE)[0].strip()


def clean_title(title: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(title or "")).strip()


def plain_price(value) -> str:
    """'R 2,500.00' / 2500 / '2500.0' -> '2500.00'. Empty when there is no usable price."""
    if value is None:
        return ""
    text = re.sub(r"[^0-9.]", "", str(value).replace(",", ""))
    try:
        number = Decimal(text)
    except InvalidOperation:
        return ""
    return f"{number:.2f}" if number > 0 else ""
