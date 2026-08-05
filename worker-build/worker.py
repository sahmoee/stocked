#!/usr/bin/env python3
"""Offline parser worker for Stocked Companion.

Reads one JSON object from stdin::

    {"mode": "parse" | "classify", "url": "https://…", "html": "<html>…"}

and writes one JSON object to stdout.  ``mode`` defaults to ``parse`` so older
callers keep working.

This process never performs network I/O: the Swift side owns every request so
that robots rules, rate limits, caching and logging stay in one policy layer.
"""

from __future__ import annotations

import html as html_module
import json
import re
import sys
import uuid
from typing import Any, Callable, Iterable

SCHEMA_RECIPE_TYPES = {"recipe"}
SCHEMA_LISTING_TYPES = {"itemlist", "collectionpage", "searchresultspage"}

RECIPE_CARD_MARKERS = (
    "wprm-recipe-container",
    "wprm-recipe-ingredient",
    "tasty-recipes",
    "mv-create-ingredients",
    "recipe-card",
    "easyrecipe",
    "zlrecipe",
    'itemprop="recipeingredient"',
    "itemprop='recipeingredient'",
    "h-recipe",
    "hrecipe",
)


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------


def safe_call(callable_value: Callable[[], Any], default: Any = None) -> Any:
    try:
        value = callable_value()
        return default if value is None else value
    except Exception:
        return default


def cleaned_text(value: Any) -> str | None:
    if value is None:
        return None
    text = re.sub(r"<[^>]+>", " ", str(value))
    text = html_module.unescape(text)
    text = re.sub(r"\s+", " ", text).strip()
    return text or None


def cleaned_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        values: Iterable[Any] = re.split(r"[,;]", value)
    elif isinstance(value, (list, tuple, set)):
        values = list(value)
    else:
        values = [value]
    result: list[str] = []
    seen: set[str] = set()
    for item in values:
        text = cleaned_text(item)
        if text and text.casefold() not in seen:
            seen.add(text.casefold())
            result.append(text)
    return result


def as_int(value: Any) -> int | None:
    """Coerce whatever a scraper hands back into whole minutes.

    ``recipe-scrapers`` returns ints for most sites but strings such as
    ``"1 hr 20 mins"`` or ``"PT45M"`` for others.  Passing those straight
    through made the Swift decoder reject the whole result, so a fully parsed
    recipe was thrown away because of one timing field.
    """
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    if isinstance(value, float):
        return int(round(value)) or None
    text = str(value).strip()
    if not text:
        return None
    if text.isdigit():
        return int(text) or None

    iso = re.fullmatch(
        r"P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?",
        text,
        re.IGNORECASE,
    )
    if iso:
        days, hours, minutes, seconds = (float(part or 0) for part in iso.groups())
        total = int(days * 1440 + hours * 60 + minutes + seconds // 60)
        return total or None

    total = 0
    matched = False
    hours_match = re.search(r"(\d+(?:\.\d+)?)\s*(?:hours?|hrs?|h)\b", text, re.IGNORECASE)
    if hours_match:
        total += int(round(float(hours_match.group(1)) * 60))
        matched = True
    minutes_match = re.search(r"(\d+)\s*(?:minutes?|mins?|m)\b", text, re.IGNORECASE)
    if minutes_match:
        total += int(minutes_match.group(1))
        matched = True
    if matched:
        return total or None

    digits = re.search(r"\d+", text)
    return int(digits.group()) if digits else None


def as_float(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    match = re.search(r"\d+(?:\.\d+)?", str(value))
    return float(match.group()) if match else None


def ingredient_section(values: list[str]) -> list[dict[str, Any]]:
    return [
        {
            "id": str(uuid.uuid4()),
            "name": None,
            "items": [
                {
                    "id": str(uuid.uuid4()),
                    "raw": value,
                    "quantity": None,
                    "quantityText": None,
                    "unit": None,
                    "name": None,
                    "preparation": None,
                    "notes": None,
                }
                for value in values
            ],
        }
    ]


def instruction_section(values: list[str]) -> list[dict[str, Any]]:
    return [{"id": str(uuid.uuid4()), "name": None, "steps": values}]


def first_number(value: str | None) -> float | None:
    if not value:
        return None
    # A number attached to a serving noun beats an unrelated leading count, in
    # either word order: "4 servings" and "Serves 4" both mean four.
    noun = r"(?:servings?|serves|portions?|people)"
    match = re.search(rf"(\d+(?:\.\d+)?)\s*{noun}", value, re.IGNORECASE) or re.search(
        rf"{noun}\s*:?\s*(\d+(?:\.\d+)?)", value, re.IGNORECASE
    )
    if match:
        return float(match.group(1))
    match = re.search(r"\d+(?:\.\d+)?", value)
    return float(match.group()) if match else None


# --------------------------------------------------------------------------
# JSON-LD
# --------------------------------------------------------------------------


def type_names(value: Any) -> list[str]:
    raw = value if isinstance(value, list) else ([value] if value is not None else [])
    names: list[str] = []
    for item in raw:
        if not isinstance(item, str):
            continue
        # Accept "Recipe", "schema:Recipe" and "https://schema.org/Recipe".
        names.append(re.split(r"[/:#]", item)[-1].casefold())
    return names


def walk_nodes(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, list):
        for item in value:
            yield from walk_nodes(item)
    elif isinstance(value, dict):
        yield value
        for nested in value.values():
            if isinstance(nested, (list, dict)):
                yield from walk_nodes(nested)


def node_score(node: dict[str, Any]) -> int:
    return (
        (2 if node.get("name") else 0)
        + min(6, len(cleaned_list(node.get("recipeIngredient"))))
        + min(6, len(flatten_steps(node.get("recipeInstructions"))))
        + (1 if node.get("image") else 0)
        + (1 if node.get("nutrition") else 0)
    )


def jsonld_scripts(page_html: str) -> list[Any]:
    pattern = re.compile(
        r"""<script[^>]*type\s*=\s*["']application/(?:ld\+)?json[^"']*["'][^>]*>(.*?)</script>""",
        re.IGNORECASE | re.DOTALL,
    )
    values: list[Any] = []
    for raw in pattern.findall(page_html):
        raw = raw.strip()
        if raw.startswith("<!--"):
            raw = raw[4:]
        if raw.endswith("-->"):
            raw = raw[:-3]
        try:
            values.append(json.loads(raw.strip()))
        except json.JSONDecodeError:
            continue
    return values


def all_nodes(page_html: str) -> list[dict[str, Any]]:
    nodes: list[dict[str, Any]] = []
    for document in jsonld_scripts(page_html):
        nodes.extend(walk_nodes(document))
    return nodes


def recipe_nodes(nodes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [node for node in nodes if set(type_names(node.get("@type"))) & SCHEMA_RECIPE_TYPES]


def scalar(value: Any) -> str | None:
    if isinstance(value, (str, int, float)):
        return cleaned_text(value)
    if isinstance(value, list):
        for item in value:
            answer = scalar(item)
            if answer:
                return answer
        return None
    if isinstance(value, dict):
        for key in ("name", "text", "headline", "url", "contentUrl", "@id"):
            answer = scalar(value.get(key))
            if answer:
                return answer
    return None


def flatten_steps(value: Any) -> list[str]:
    if isinstance(value, str):
        parts = [cleaned_text(part) for part in re.split(r"(?:\r?\n)+", value)]
        return [part for part in parts if part]
    if isinstance(value, list):
        result: list[str] = []
        for item in value:
            result.extend(flatten_steps(item))
        return cleaned_list(result)
    if isinstance(value, dict):
        if "itemListElement" in value and not value.get("text"):
            return flatten_steps(value["itemListElement"])
        text = cleaned_text(value.get("text"))
        if text:
            return [text]
        name = cleaned_text(value.get("name"))
        if name:
            return [name]
    return []


# --------------------------------------------------------------------------
# Parsers
# --------------------------------------------------------------------------


def result_from_recipe_scrapers(page_html: str, url: str) -> dict[str, Any]:
    from recipe_scrapers import scrape_html

    try:
        scraper = scrape_html(page_html, url, wild_mode=True)
    except TypeError:
        # Older and newer releases disagree on whether wild_mode is exposed.
        scraper = scrape_html(page_html, url)

    def method(name: str, default: Any = None) -> Any:
        return safe_call(lambda: getattr(scraper, name)(), default)

    title = cleaned_text(method("title"))
    ingredients = cleaned_list(method("ingredients", []))

    steps = cleaned_list(method("instructions_list", []))
    if not steps:
        instructions_text = method("instructions", "") or ""
        steps = [
            value
            for value in (
                cleaned_text(part) for part in re.split(r"(?:\r?\n)+", instructions_text)
            )
            if value
        ]

    if not title or not ingredients or not steps:
        raise ValueError("The site adapter did not return title, ingredients and instructions.")

    yield_text = cleaned_text(method("yields"))
    nutrients_raw = method("nutrients", {})
    nutrients = (
        {str(key): str(value) for key, value in nutrients_raw.items() if value not in (None, "")}
        if isinstance(nutrients_raw, dict)
        else {}
    )

    warnings: list[str] = []
    if len(ingredients) < 3:
        warnings.append(f"Only {len(ingredients)} ingredients were extracted.")
    if len(steps) < 2:
        warnings.append(f"Only {len(steps)} instruction step was extracted.")

    image = cleaned_text(method("image"))
    confidence = min(
        0.98,
        0.64
        + min(0.12, len(ingredients) * 0.01)
        + min(0.12, len(steps) * 0.015)
        + (0.04 if image else 0)
        + (0.03 if yield_text else 0),
    )

    return {
        "title": title,
        "summary": cleaned_text(method("description")),
        "canonicalURL": cleaned_text(method("canonical_url")) or url,
        "author": cleaned_text(method("author")),
        "imageURL": image,
        "ingredientSections": ingredient_section(ingredients),
        "instructionSections": instruction_section(steps),
        "yield": yield_text,
        "servings": first_number(yield_text),
        "times": {
            "prepMinutes": as_int(method("prep_time")),
            "cookMinutes": as_int(method("cook_time")),
            "totalMinutes": as_int(method("total_time")),
        },
        "nutrition": nutrients,
        "cuisines": cleaned_list(method("cuisine")),
        "categories": cleaned_list(method("category")),
        "keywords": cleaned_list(method("keywords", [])),
        "diets": [],
        "confidence": confidence,
        "warnings": warnings,
        "parser": "recipe-scrapers Python worker",
    }


def result_from_jsonld(page_html: str, url: str) -> dict[str, Any]:
    candidates = recipe_nodes(all_nodes(page_html))
    node = max(candidates, key=node_score, default=None)
    if not node:
        raise ValueError("No Schema.org Recipe JSON-LD was found.")

    title = scalar(node.get("name"))
    ingredients = cleaned_list(node.get("recipeIngredient"))
    steps = flatten_steps(node.get("recipeInstructions"))
    if not title or not ingredients or not steps:
        raise ValueError("The Recipe JSON-LD is missing title, ingredients or instructions.")

    yield_text = scalar(node.get("recipeYield"))
    nutrition_raw = node.get("nutrition")
    nutrition = {}
    if isinstance(nutrition_raw, dict):
        nutrition = {
            str(key): str(value)
            for key, value in nutrition_raw.items()
            if key not in {"@type", "@context", "@id"} and value not in (None, "")
        }

    prep = as_int(scalar(node.get("prepTime")))
    cook = as_int(scalar(node.get("cookTime")))
    total = as_int(scalar(node.get("totalTime")))
    if total is None and prep is not None and cook is not None:
        total = prep + cook

    return {
        "title": title,
        "summary": scalar(node.get("description")),
        "canonicalURL": scalar(node.get("url")) or url,
        "author": scalar(node.get("author")),
        "imageURL": scalar(node.get("image")),
        "ingredientSections": ingredient_section(ingredients),
        "instructionSections": instruction_section(steps),
        "yield": yield_text,
        "servings": as_float(node.get("recipeYield")) or first_number(yield_text),
        "times": {"prepMinutes": prep, "cookMinutes": cook, "totalMinutes": total},
        "nutrition": nutrition,
        "cuisines": cleaned_list(node.get("recipeCuisine")),
        "categories": cleaned_list(node.get("recipeCategory")),
        "keywords": cleaned_list(node.get("keywords")),
        "diets": [
            value.rsplit("/", 1)[-1] for value in cleaned_list(node.get("suitableForDiet"))
        ],
        "confidence": min(
            0.95,
            0.67 + min(0.12, len(ingredients) * 0.01) + min(0.12, len(steps) * 0.015),
        ),
        "warnings": [],
        "parser": "Python JSON-LD fallback",
    }


def result_from_microdata(page_html: str, url: str) -> dict[str, Any]:
    """Last-resort extraction for pages that publish only microdata."""

    def values(prop: str) -> list[str]:
        found = re.findall(
            rf"""<[a-z0-9]+[^>]*itemprop\s*=\s*["'][^"']*\b{prop}\b[^"']*["'][^>]*"""
            rf"""content\s*=\s*["']([^"']*)["']""",
            page_html,
            re.IGNORECASE | re.DOTALL,
        )
        found += re.findall(
            rf"""<([a-z0-9]+)[^>]*itemprop\s*=\s*["'][^"']*\b{prop}\b[^"']*["'][^>]*>(.*?)</\1>""",
            page_html,
            re.IGNORECASE | re.DOTALL,
        )
        flat: list[str] = []
        for item in found:
            flat.append(item[1] if isinstance(item, tuple) else item)
        return cleaned_list(flat)

    if not re.search(r"""itemtype\s*=\s*["'][^"']*schema\.org/Recipe""", page_html, re.IGNORECASE):
        raise ValueError("No Schema.org Recipe microdata was found.")

    ingredients = values("recipeIngredient") or values("ingredients")
    steps = values("recipeInstructions") or values("instructions")
    names = values("name")
    if names:
        title = names[0]
    else:
        title_match = re.search(r"<title[^>]*>(.*?)</title>", page_html, re.IGNORECASE | re.DOTALL)
        title = cleaned_text(title_match.group(1)) if title_match else None
    if not title or not ingredients or not steps:
        raise ValueError("The Recipe microdata is missing title, ingredients or instructions.")

    yield_values = values("recipeYield")
    yield_text = yield_values[0] if yield_values else None
    prep = as_int(next(iter(values("prepTime")), None))
    cook = as_int(next(iter(values("cookTime")), None))
    total = as_int(next(iter(values("totalTime")), None))
    if total is None and prep is not None and cook is not None:
        total = prep + cook

    return {
        "title": title,
        "summary": next(iter(values("description")), None),
        "canonicalURL": url,
        "author": next(iter(values("author")), None),
        "imageURL": next(iter(values("image")), None),
        "ingredientSections": ingredient_section(ingredients),
        "instructionSections": instruction_section(steps),
        "yield": yield_text,
        "servings": first_number(yield_text),
        "times": {"prepMinutes": prep, "cookMinutes": cook, "totalMinutes": total},
        "nutrition": {},
        "cuisines": values("recipeCuisine"),
        "categories": values("recipeCategory"),
        "keywords": values("keywords"),
        "diets": values("suitableForDiet"),
        "confidence": 0.6,
        "warnings": ["Extracted from microdata; review the result carefully."],
        "parser": "Python microdata fallback",
    }


def parse(page_html: str, url: str) -> dict[str, Any]:
    errors: list[str] = []
    for name, parser in (
        ("recipe-scrapers", result_from_recipe_scrapers),
        ("JSON-LD fallback", result_from_jsonld),
        ("microdata fallback", result_from_microdata),
    ):
        try:
            return parser(page_html, url)
        except Exception as error:  # noqa: BLE001 - the message is reported upward
            errors.append(f"{name}: {error}")
    raise ValueError(" | ".join(errors))


# --------------------------------------------------------------------------
# Classification
# --------------------------------------------------------------------------


def classify(page_html: str, url: str) -> dict[str, Any]:
    """Report whether a page publishes exactly one recipe.

    Used as a second opinion for link discovery so that category pages,
    tag archives and "25 best" roundups never reach the import queue.
    """
    nodes = all_nodes(page_html)
    recipes = recipe_nodes(nodes)
    evidence: list[str] = []
    score = 0.0

    if recipes:
        best = max(recipes, key=node_score)
        ingredients = len(cleaned_list(best.get("recipeIngredient")))
        steps = len(flatten_steps(best.get("recipeInstructions")))
        if ingredients >= 2 and steps >= 1:
            score += 0.62
            evidence.append(f"Recipe JSON-LD with {ingredients} ingredients and {steps} steps")
        else:
            score += 0.12
            evidence.append("Recipe JSON-LD without a complete ingredient or method list")

    if len(recipes) > 1:
        score -= 0.35
        evidence.append(f"{len(recipes)} Recipe nodes on one page (roundup)")

    for node in nodes:
        if set(type_names(node.get("@type"))) & SCHEMA_LISTING_TYPES:
            score -= 0.3
            evidence.append("The page declares itself a collection or search page")
            break

    lowered = page_html.casefold()
    marker = next((value for value in RECIPE_CARD_MARKERS if value in lowered), None)
    if marker:
        score += 0.25
        evidence.append(f"Recipe card markup ({marker})")

    if re.search(r"""<link[^>]*rel\s*=\s*["']next["']""", page_html, re.IGNORECASE):
        score -= 0.2
        evidence.append("Declares rel=next pagination")

    title = scalar(max(recipes, key=node_score).get("name")) if recipes else None
    if not title:
        title_match = re.search(r"<title[^>]*>(.*?)</title>", page_html, re.IGNORECASE | re.DOTALL)
        title = cleaned_text(title_match.group(1)) if title_match else None
    if title and (
        re.match(r"^\s*\d+\s+(best|easy|amazing|favorite|top)\b", title, re.IGNORECASE)
        or (
            re.match(r"^\s*\d{1,3}\s+", title)
            and re.search(r"\b(recipes?|ideas|ways|dishes|meals)\b", title, re.IGNORECASE)
        )
    ):
        score -= 0.4
        evidence.append("The headline reads as a roundup")

    return {
        "isRecipe": score >= 0.55,
        "title": title,
        "evidence": evidence or ["No recipe signals were found"],
    }


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def main() -> int:
    try:
        request = json.load(sys.stdin)
        url = request.get("url")
        page_html = request.get("html")
        mode = request.get("mode") or "parse"
        if not isinstance(url, str) or not isinstance(page_html, str):
            raise ValueError("The request must contain string url and html values.")
        if mode not in {"parse", "classify"}:
            raise ValueError(f"Unsupported mode: {mode}")

        if mode == "classify":
            response = {
                "ok": True,
                "result": None,
                "classification": classify(page_html, url),
                "error": None,
            }
        else:
            response = {
                "ok": True,
                "result": parse(page_html, url),
                "classification": None,
                "error": None,
            }
        json.dump(response, sys.stdout, ensure_ascii=False, separators=(",", ":"))
        return 0
    except Exception as error:  # noqa: BLE001 - reported to the caller as JSON
        json.dump(
            {"ok": False, "result": None, "classification": None, "error": str(error)},
            sys.stdout,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
