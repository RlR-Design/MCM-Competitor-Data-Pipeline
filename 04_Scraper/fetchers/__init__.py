"""
Platform fetchers. Each module has fetch(shop, http, run, limit) -> List[RawProduct]
returning the shop's currently available products. Listing failures raise (the
shop is marked FAILED); single product failures are counted and mark it PARTIAL.
Shopify is the exception: it is read over several sessions with
shopify.session() (see shopify.py and main.py).
"""

from . import pagelayer, shopify, wix, woocommerce

FETCHERS = {
    "shopify": None,                # read in sessions: shopify.session (see main.py)
    "woocommerce": woocommerce.fetch,
    "pagelayer": pagelayer.fetch,
    "wix": wix.fetch,
}
