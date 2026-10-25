"""
===============================================================================
Script   : extraction.py
Layer    : Scraper
Purpose  : Fills category, makers, primary_material, era, condition and
           dimensions by sending batches of raw products to Claude Code in
           headless mode (claude -p). No API key: it runs on the Claude login
           of this Mac and counts toward that plan's usage.
           Results are cached per URL; a product is sent again only when its
           text changes or vocab.VERSION changes.
Requires : Claude Code CLI installed and logged in (claude on PATH, or CLAUDE_BIN).
Settings : CLAUDE_BIN        path to the claude command (default: claude)
           EXTRACT_MODEL     model passed to claude --model (default: Claude Code's default)
           EXTRACT_BATCH     products per Claude call (default: 20)
Warning  : Every answer is checked against vocab.py; invalid values are dropped
           (left empty), never written as given.
===============================================================================
"""

import hashlib
import json
import os
import subprocess
from pathlib import Path
from typing import Callable, Dict, List, Tuple

import vocab
from common import RawProduct

PROMPT_FILE = Path(__file__).with_name("extract_prompt.md")
MAX_TEXT = 3000          # characters of description sent per product


class ExtractionError(Exception):
    """Claude could not be run or gave no usable answer."""


def fingerprint(p: RawProduct) -> str:
    """Changes when the text Claude sees changes (not when only the price changes)."""
    hints = {k: v for k, v in p.hints.items() if k != "compare_at_price"}
    payload = json.dumps([p.title, p.description, p.source_category, hints], sort_keys=True)
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()


class Cache:
    """URL -> {fingerprint, version, fields}, stored as JSON."""

    def __init__(self, path: Path):
        self.path = path
        self.entries: Dict[str, dict] = {}
        if path.exists():
            self.entries = json.loads(path.read_text(encoding="utf-8"))

    def get(self, p: RawProduct):
        e = self.entries.get(p.url)
        if e and e.get("fingerprint") == fingerprint(p) and e.get("version") == vocab.VERSION:
            return e["fields"]
        return None

    def put(self, p: RawProduct, fields: Dict[str, str]) -> None:
        self.entries[p.url] = {"fingerprint": fingerprint(p), "version": vocab.VERSION, "fields": fields}

    def makers(self) -> List[str]:
        seen = {e["fields"].get("makers", "") for e in self.entries.values()}
        return sorted(m for m in seen if m)

    def save(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.entries, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(self.path)


def build_prompt(batch: List[Tuple[str, RawProduct]], makers: List[str]) -> str:
    items = []
    for pid, p in batch:
        item = {"id": pid, "title": p.title, "text": p.description[:MAX_TEXT]}
        if p.source_category:
            item["shop_category"] = p.source_category
        hints = {k: v for k, v in p.hints.items() if k != "compare_at_price"}
        if hints:
            item["hints"] = hints
        items.append(item)
    bullet = lambda values: "\n".join(f"- {v}" for v in values)
    return PROMPT_FILE.read_text(encoding="utf-8").format(
        categories=bullet(vocab.CATEGORIES),
        materials=bullet(vocab.MATERIALS),
        woods=", ".join(vocab.WOODS),
        eras=bullet(vocab.ERAS),
        conditions=bullet(vocab.CONDITIONS),
        makers=", ".join(sorted(set(vocab.KNOWN_MAKERS) | set(makers))),
        products=json.dumps(items, ensure_ascii=False, indent=1),
    )


def run_claude(prompt: str) -> str:
    """Send one prompt to claude -p and return the text of its answer."""
    cmd = [os.environ.get("CLAUDE_BIN", "claude"), "-p", "--output-format", "json"]
    if os.environ.get("EXTRACT_MODEL"):
        cmd += ["--model", os.environ["EXTRACT_MODEL"]]
    try:
        proc = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=900)
    except FileNotFoundError as exc:
        raise ExtractionError("claude command not found (install Claude Code or set CLAUDE_BIN)") from exc
    except subprocess.TimeoutExpired as exc:
        raise ExtractionError("claude did not answer within 15 minutes") from exc
    try:
        envelope = json.loads(proc.stdout)
    except ValueError:
        envelope = None
    if proc.returncode != 0 or not isinstance(envelope, dict) or envelope.get("is_error"):
        detail = (envelope or {}).get("result") if isinstance(envelope, dict) else None
        detail = detail or proc.stderr.strip() or proc.stdout.strip()
        raise ExtractionError(f"claude failed (exit {proc.returncode}): {str(detail)[:300]}")
    return envelope.get("result", "")


def parse_answer(text: str) -> List[dict]:
    start, end = text.find("["), text.rfind("]")
    if start < 0 or end < start:
        raise ExtractionError("answer has no JSON array")
    try:
        data = json.loads(text[start:end + 1])
    except ValueError as exc:
        raise ExtractionError(f"answer is not valid JSON: {exc}") from exc
    return [d for d in data if isinstance(d, dict)]


def extract(products: List[RawProduct], cache_path: Path,
            runner: Callable[[str], str] = run_claude) -> Tuple[Dict[str, Dict[str, str]], List[str]]:
    """Fields per URL for every product, and the URLs still pending (batch failed)."""
    cache = Cache(cache_path)
    results: Dict[str, Dict[str, str]] = {}
    todo: List[RawProduct] = []
    for p in products:
        hit = cache.get(p)
        if hit is not None:
            results[p.url] = hit
        else:
            todo.append(p)
    print(f"Extraction: {len(results)} from cache, {len(todo)} to send to Claude", flush=True)

    size = int(os.environ.get("EXTRACT_BATCH", "20"))
    pending: List[str] = []
    rejected: Dict[str, int] = {}
    for start in range(0, len(todo), size):
        batch = [(str(i), p) for i, p in enumerate(todo[start:start + size])]
        label = f"batch {start // size + 1} of {(len(todo) + size - 1) // size}"
        answers = None
        for attempt in (1, 2):
            try:
                answers = {a.get("id"): a for a in parse_answer(runner(build_prompt(batch, cache.makers())))}
                break
            except ExtractionError as exc:
                print(f"  [!] {label}, attempt {attempt}: {exc}", flush=True)
        if answers is None:
            pending.extend(p.url for _, p in batch)
            if start == 0:
                # The first batch failing twice usually means Claude is not available; stop early.
                pending.extend(p.url for p in todo[size:])
                break
            continue
        for pid, p in batch:
            answer = answers.get(pid)
            if answer is None:
                pending.append(p.url)
                continue
            fields = vocab.clean_fields(answer)
            for f in vocab.rejected_fields(answer, fields):
                rejected[f] = rejected.get(f, 0) + 1
            cache.put(p, fields)
            results[p.url] = fields
        cache.save()
        print(f"  {label} done", flush=True)
    if rejected:
        print(f"  Values dropped by validation: {rejected}", flush=True)
    return results, pending
