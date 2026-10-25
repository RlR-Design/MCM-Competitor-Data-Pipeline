"""
===============================================================================
Script   : vocab.py
Layer    : Scraper
Purpose  : Standard value lists for the extracted fields (category, primary
           material, era, condition) and the checks applied to Claude's answers.
When     : Edit to change a list. Bump VERSION so cached extractions are redone.
Warning  : Reporting groups by these exact spellings. Renaming a value splits
           history unless the old value is mapped in the warehouse.
===============================================================================
"""

import re
from typing import Dict, List

# Bump when a list or rule changes: cached extractions with another version are redone.
VERSION = "1"

# Category groups are for reporting; each product gets one category.
CATEGORY_GROUPS: Dict[str, List[str]] = {
    "Seating": ["Armchairs", "Sofas & Daybeds", "Dining Chairs", "Stools & Benches", "Dining Sets"],
    "Tables": ["Dining Tables", "Coffee Tables", "Side & Nesting Tables", "Console Tables",
               "Desks & Bureaus", "Dressing Tables"],
    "Storage": ["Sideboards & Servers", "Chests of Drawers", "Cabinets & Display Cabinets",
                "Bookcases & Shelving", "Wall Units", "Bar & Drinks Cabinets", "Drinks Trolleys",
                "Bedside Tables", "Storage Chests & Kists"],
    "Bedroom & other": ["Beds & Headboards", "Outdoor Furniture", "Other Furniture"],
    "Decor": ["Lighting", "Mirrors", "Wall Art", "Vases & Ceramics", "Glassware & Barware",
              "Tableware & Kitchenware", "Decor & Collectibles", "Rugs & Textiles"],
}
CATEGORIES: List[str] = [c for group in CATEGORY_GROUPS.values() for c in group]

# Woods can be written as "Solid <wood>", "<wood> Veneer" or "<wood>" (not stated).
WOODS: List[str] = ["Kiaat", "Imbuia", "Sapele Mahogany", "Teak", "Rosewood", "Oak", "Walnut",
                    "Beech", "Birch", "Maple", "Elm", "Hardwood"]
MATERIALS: List[str] = WOODS + [
    "Plywood & Veneer", "Rattan & Cane",
    "Brass", "Chrome", "Steel", "Aluminium", "Iron", "Copper & Bronze",
    "Glass", "Ceramic & Porcelain", "Stone & Marble", "Plastic & Fibreglass",
    "Fabric", "Leather", "Paper",
]

ERAS: List[str] = [
    "Arts & Crafts, 1900–1910s",
    "Art Nouveau, 1900–1910s",
    "Art Deco, 1920s–1930s",
    "Streamline Moderne, 1930s–1940s",
    "Mid-Century Modern, 1945–1960s",
    "Retro, 1970s",
    "Postmodern / Memphis, 1980s",
    "90s Minimalism, 1990s",
]

CONDITIONS: List[str] = [
    "Restored & Refurbished",
    "Excellent (Original / Preserved)",
    "Good (Vintage Wear / Authentic)",
    "Fair / As-Is (Flaws / Repairs / Unrestored)",
]

# Canonical maker spellings, offered to Claude so the same maker is written the same way.
# Makers already in the extraction cache are added at run time.
KNOWN_MAKERS: List[str] = [
    "DS Vorster", "Artecasa", "Frystark", "Kallenbach", "John Tabraham for Kallenbach",
    "Novocraft", "Torrente", "Duros", "Bakker & Steyger", "Greaves & Thomas", "Lubis",
    "E.E. Meyer for Binnehuis", "Parker Knoll", "G-Plan", "Grafton Everest", "Airflex",
    "Ercol", "White and Newton",
]

EXTRACTED_FIELDS = ["category", "makers", "primary_material", "era", "condition", "dimensions"]

_DIMENSION_KEY = re.compile(r"\b(L|W|H|D|SH|DM):\s")
_PLACEHOLDERS = {"unknown", "none", "null", "n/a", "-"}


def is_valid_material(value: str) -> bool:
    if value in MATERIALS:
        return True
    if value.startswith("Solid ") and value[6:] in WOODS:
        return True
    return value.endswith(" Veneer") and value[:-7] in WOODS


def clean_fields(answer: Dict[str, object]) -> Dict[str, str]:
    """Keep only valid values; anything else becomes empty (the warehouse fills the default)."""
    out = {}
    for name in EXTRACTED_FIELDS:
        value = answer.get(name)
        out[name] = re.sub(r"\s+", " ", value).strip() if isinstance(value, str) else ""
    if out["category"] not in CATEGORIES:
        out["category"] = ""
    if not is_valid_material(out["primary_material"]):
        out["primary_material"] = ""
    if out["era"] not in ERAS:
        out["era"] = ""
    if out["condition"] not in CONDITIONS:
        out["condition"] = ""
    if out["makers"].lower() in _PLACEHOLDERS:
        out["makers"] = ""
    out["makers"] = out["makers"][:120]
    if not _DIMENSION_KEY.search(out["dimensions"]):
        out["dimensions"] = ""
    return out


def rejected_fields(answer: Dict[str, object], cleaned: Dict[str, str]) -> List[str]:
    """Fields where Claude gave a value that failed validation."""
    return [f for f in EXTRACTED_FIELDS
            if isinstance(answer.get(f), str) and answer[f].strip().lower() not in _PLACEHOLDERS | {""}
            and not cleaned[f]]
