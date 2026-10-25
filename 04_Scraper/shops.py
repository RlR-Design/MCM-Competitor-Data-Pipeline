"""
===============================================================================
Script   : shops.py
Layer    : Scraper
Purpose  : The Shop settings record and the shop list loader. The real shop
           list lives in shops_config.py (local, git-ignored); the committed
           shops_config.example.py shows the format.
When     : Add a shop on a supported platform (shopify, woocommerce,
           pagelayer, wix) with a new entry in shops_config.py and a
           ref_shop_locations row (01_DDL/04_create_reference_tables.sql).
Warning  : The shop name must match ref_shop_locations / ref_shop_rules exactly.
           Changing base_url changes every product URL, which is the product's
           identity in the warehouse. Keep it identical to earlier scrapes.
===============================================================================
"""

from dataclasses import dataclass, field
from typing import Dict, List, Tuple


@dataclass(frozen=True)
class Shop:
    name: str
    platform: str            # shopify | woocommerce | pagelayer | wix
    base_url: str            # no trailing slash
    region: str
    city: str
    latitude: float
    longitude: float
    # Regex markers where the shop's boilerplate starts (delivery, returns, ...).
    # Description text is cut at the first match.
    boilerplate: Tuple[str, ...] = ()
    # Seconds between requests to this shop.
    delay: float = 1.0
    # Platform-specific settings (e.g. listing categories for pagelayer).
    options: Dict[str, List[str]] = field(default_factory=dict)


def load_shops() -> List[Shop]:
    """The shop list from shops_config.py."""
    try:
        from shops_config import SHOPS
    except ImportError as exc:
        raise SystemExit("shops_config.py not found: copy shops_config.example.py and fill in the shops") from exc
    return list(SHOPS)


def select_shops(names: str = "") -> List[Shop]:
    """All shops, or the comma-separated names given (case-insensitive)."""
    shops = load_shops()
    if not names:
        return shops
    wanted = {n.strip().lower() for n in names.split(",") if n.strip()}
    chosen = [s for s in shops if s.name.lower() in wanted]
    unknown = wanted - {s.name.lower() for s in chosen}
    if unknown:
        raise ValueError(f"Unknown shop(s): {', '.join(sorted(unknown))}")
    return chosen
