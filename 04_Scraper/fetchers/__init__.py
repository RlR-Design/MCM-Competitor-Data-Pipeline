"""
Platform fetchers. Each module has fetch(shop, http, run, limit) -> List[RawProduct]
returning the shop's currently available products. Listing failures raise (the
shop is marked FAILED); single product failures are counted and mark it PARTIAL.
"""

from . import pagelayer, shopify, wix, woocommerce

FETCHERS = {
    "shopify": shopify.fetch,
    "woocommerce": woocommerce.fetch,
    "pagelayer": pagelayer.fetch,
    "wix": wix.fetch,
}
