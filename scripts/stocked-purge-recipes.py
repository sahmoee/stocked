#!/usr/bin/env python3
"""
stocked-purge-recipes.py — strip retired recipe sources out of Stocked data files.

Two sources are retired: the bundled Kaggle food dataset and the "Sowens" curated feed.
The apps refuse them at the point of storage and sweep them at launch (Build 89), but data
files sitting outside the apps — backups, published catalogues, seed JSON, spreadsheets
exported from Kitchen Transfer — are not touched by that. This script is for those.

WHAT IT UNDERSTANDS

  Stocked backup / snapshot JSON   {"recipes": [...], "savedRecipes": [...], ...}
  Bare recipe array                [ {...}, {...} ]
  Wrapped catalogue                {"version": 3, "recipes": [...]}
  Kaggle export                    {"version": 2, "source": "...", "recipes": [...]}
  NDJSON                           one JSON object per line
  Recipe CSV                       the Build 88 export — library,id,title,...,source,...

HOW IT DECIDES

  A recipe is blocked when any of these, lowercased, says so:
    • a source field ("source", "sourceName", "source_name", "publisher", "site")
      contains "kaggle" or "sowens"
    • a URL field ("sourceURL", "source_url", "url", "link", "imageURL", "image")
      contains "kaggle.com" or "kaggle.io"
    • the id starts with "sowens-" or "kaggle-"
    • a tag is exactly "kaggle" or "sowens" (whole tag, not substring — "kaggle-style"
      is somebody's own tag and is left alone)

  Titles, descriptions and steps are never read. A recipe called "Sowens Farmhouse Loaf"
  that somebody wrote themselves survives. This matches RecipeSourceBlocklist.swift in the
  iOS app and MacRecipeSourceBlocklist.swift on the Mac exactly — change one, change all
  three, or the apps and the script will disagree about what to remove.

HOW IT BEHAVES

  Dry run unless you pass --apply. Nothing is ever deleted without a backup: the original
  is copied to <name>.bak (or --backup-dir) before the file is rewritten, and seed files
  matched by name are MOVED into a _purged/ folder rather than unlinked.

USAGE

  Look, don't touch — the default:
      python3 stocked-purge-recipes.py ~/Documents/Stocked

  Do it:
      python3 stocked-purge-recipes.py ~/Documents/Stocked --apply

  Turn anything — a backup, an export, a folder of both — into a removal list the apps
  can read back, without changing the files it read:
      python3 stocked-purge-recipes.py ~/Documents/Stocked --removal-csv remove-these.csv

  Move the retired seed files out of a repo before a build:
      python3 stocked-purge-recipes.py ./Stocked --apply --move-seed-files

  Machine-readable summary for CI:
      python3 stocked-purge-recipes.py ./data --json-report report.json

Exit codes: 0 nothing blocked (or all of it removed), 1 blocked recipes found in a dry
run, 2 a file could not be read or written or a named target does not exist. The 1
makes it usable as a CI gate; the 2 means a mistyped path fails loudly rather than
reporting a clean bill of health for a folder that was never scanned.

No third-party packages. Python 3.8+.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import shutil
import sys
from typing import Any, Dict, Iterable, List, Optional, Tuple

# ---------------------------------------------------------------------------
# The blocklist — keep in step with the two Swift copies.
# ---------------------------------------------------------------------------

BLOCKED_SOURCE_FRAGMENTS = ("kaggle", "sowens")
BLOCKED_URL_FRAGMENTS = ("kaggle.com", "kaggle.io")
BLOCKED_ID_PREFIXES = ("sowens-", "kaggle-")
BLOCKED_FILE_FRAGMENTS = ("kaggle", "sowens")

SOURCE_KEYS = ("source", "sourceName", "source_name", "sourcename",
               "publisher", "site", "siteName", "provider")
URL_KEYS = ("sourceURL", "source_url", "sourceurl", "url", "link",
            "imageURL", "image_url", "imageurl", "image", "thumbnail")
ID_KEYS = ("id", "recipeId", "recipe_id", "uid", "slug")
TAG_KEYS = ("tags", "keywords", "labels")
# Saved generated recipes carry no tag list — their only free-text slot is the meal
# category, which is what the Swift `GeneratedRecipe` overload checks. Treated as a
# single tag here so the script and the two apps agree on the same rows.
SINGLE_TAG_KEYS = ("mealCategory", "meal_category", "mealcategory", "category", "cuisine")

# Keys whose value is a list of recipes, in the order we prefer to find them.
RECIPE_ARRAY_KEYS = ("recipes", "savedRecipes", "saved_recipes", "userRecipes",
                     "user_recipes", "savedGeneratedRecipes", "items", "data",
                     "results", "entries")


def _norm(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    return value.strip().lower()


def is_blocked_recipe(obj: Any) -> Tuple[bool, str]:
    """Return (blocked, why). `why` is empty when not blocked."""
    if not isinstance(obj, dict):
        return False, ""

    for key in SOURCE_KEYS:
        text = _norm(obj.get(key))
        if not text:
            continue
        for fragment in BLOCKED_SOURCE_FRAGMENTS:
            if fragment in text:
                return True, '{}="{}"'.format(key, obj.get(key))

    for key in URL_KEYS:
        text = _norm(obj.get(key))
        if not text:
            continue
        for fragment in BLOCKED_URL_FRAGMENTS:
            if fragment in text:
                return True, '{}="{}"'.format(key, obj.get(key))

    for key in ID_KEYS:
        text = _norm(obj.get(key))
        if not text:
            continue
        for prefix in BLOCKED_ID_PREFIXES:
            if text.startswith(prefix):
                return True, '{}="{}"'.format(key, obj.get(key))

    for key in TAG_KEYS:
        tags = obj.get(key)
        if isinstance(tags, str):
            tags = [t for t in tags.replace("|", ";").split(";")]
        if not isinstance(tags, list):
            continue
        for tag in tags:
            if _norm(tag) in BLOCKED_SOURCE_FRAGMENTS:
                return True, 'tag="{}"'.format(tag)

    for key in SINGLE_TAG_KEYS:
        if _norm(obj.get(key)) in BLOCKED_SOURCE_FRAGMENTS:
            return True, '{}="{}"'.format(key, obj.get(key))

    return False, ""


def is_blocked_filename(name: str) -> bool:
    lowered = os.path.basename(name).lower()
    return any(fragment in lowered for fragment in BLOCKED_FILE_FRAGMENTS)


def title_of(obj: Any) -> str:
    if not isinstance(obj, dict):
        return "(not a recipe object)"
    for key in ("title", "name", "strMeal", "recipeName"):
        value = obj.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return "(untitled)"


# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------


class Finding:
    __slots__ = ("path", "where", "title", "why", "recipe")

    def __init__(self, path: str, where: str, title: str, why: str,
                 recipe: Optional[Dict[str, Any]] = None) -> None:
        self.path = path
        self.where = where      # e.g. 'recipes[12]' or 'row 41'
        self.title = title
        self.why = why
        # The offending object itself, kept so `--removal-csv` can describe the recipe
        # in the app's own spreadsheet columns. Every format populates this, which is
        # what lets a JSON backup produce a spreadsheet the app can act on.
        self.recipe = recipe if isinstance(recipe, dict) else {}

    def as_dict(self) -> Dict[str, str]:
        return {"file": self.path, "at": self.where, "title": self.title, "reason": self.why}

    def _field(self, *names: str) -> str:
        for name in names:
            value = self.recipe.get(name)
            if isinstance(value, list):
                value = ";".join(str(part) for part in value if str(part).strip())
            if isinstance(value, str) and value.strip():
                return value.strip()
        return ""

    def csv_row(self) -> List[str]:
        """One row in the Build 88 recipe-CSV shape, with `remove` already set to yes."""
        library = self._field("library")
        if not library:
            # Saved generated recipes live under a different key; the walker records the
            # key it found them under, so `savedRecipes[3]` is enough to tell them apart.
            where = self.where.lower()
            library = "saved" if "saved" in where or "generated" in where else "recipes"
        return [
            library,
            self._field("id", "recipeId", "recipe_id", "uid", "slug"),
            self.title,
            self._field("cuisine", "area", "strArea"),
            self._field("category", "mealCategory", "meal_category", "strCategory"),
            self._field("tags", "keywords", "labels"),
            self._field("source", "sourceName", "source_name", "publisher", "provider"),
            self._field("created", "createdAt", "created_at", "dateAdded"),
            "yes",
        ]

    def __str__(self) -> str:
        return "    {:<28} {:<44} {}".format(self.where, self.title[:44], self.why)


class FileResult:
    def __init__(self, path: str, kind: str) -> None:
        self.path = path
        self.kind = kind
        self.findings: List[Finding] = []
        self.kept = 0
        self.error: Optional[str] = None
        self.rewritten = False
        self.moved_to: Optional[str] = None

    @property
    def removed(self) -> int:
        return len(self.findings)


# ---------------------------------------------------------------------------
# JSON walking
# ---------------------------------------------------------------------------


def purge_json_value(value: Any, path_label: str, result: FileResult) -> Tuple[Any, bool]:
    """Walk a decoded JSON tree, dropping blocked recipes from every list it finds.

    Returns (new_value, changed). Recurses into dicts and lists so a nested backup — a
    household export with recipes under two different keys, say — is handled without
    needing a schema for it.
    """
    changed = False

    if isinstance(value, list):
        kept: List[Any] = []
        for index, item in enumerate(value):
            blocked, why = is_blocked_recipe(item)
            if blocked:
                result.findings.append(
                    Finding(result.path, "{}[{}]".format(path_label, index),
                            title_of(item), why, item))
                changed = True
                continue
            new_item, item_changed = purge_json_value(
                item, "{}[{}]".format(path_label, index), result)
            changed = changed or item_changed
            kept.append(new_item)
            if isinstance(item, dict):
                result.kept += 1
        return kept, changed

    if isinstance(value, dict):
        out: Dict[str, Any] = {}
        for key, sub in value.items():
            label = key if not path_label else "{}.{}".format(path_label, key)
            new_sub, sub_changed = purge_json_value(sub, label, result)
            changed = changed or sub_changed
            out[key] = new_sub
        # Keep a declared count honest if the file carries one.
        if changed and "count" in out and isinstance(out.get("count"), int):
            for key in RECIPE_ARRAY_KEYS:
                if isinstance(out.get(key), list):
                    out["count"] = len(out[key])
                    break
        return out, changed

    return value, False


def process_json(path: str, result: FileResult) -> Optional[str]:
    """Returns the new file text when something changed, else None."""
    try:
        with io.open(path, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except (OSError, UnicodeDecodeError) as exc:
        result.error = "could not read: {}".format(exc)
        return None

    try:
        decoded = json.loads(raw)
    except ValueError as exc:
        result.error = "not valid JSON: {}".format(exc)
        return None

    cleaned, changed = purge_json_value(decoded, "", result)
    if not changed:
        return None

    indent = 2 if ("\n  " in raw or "\n    " in raw) else None
    return json.dumps(cleaned, indent=indent, ensure_ascii=False) + ("\n" if raw.endswith("\n") else "")


def process_ndjson(path: str, result: FileResult) -> Optional[str]:
    try:
        with io.open(path, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except (OSError, UnicodeDecodeError) as exc:
        result.error = "could not read: {}".format(exc)
        return None

    kept_lines: List[str] = []
    changed = False
    for number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped:
            kept_lines.append(line)
            continue
        try:
            obj = json.loads(stripped)
        except ValueError:
            kept_lines.append(line)        # leave anything unparseable exactly as found
            continue
        blocked, why = is_blocked_recipe(obj)
        if blocked:
            result.findings.append(
                Finding(result.path, "line {}".format(number), title_of(obj), why, obj))
            changed = True
            continue
        result.kept += 1
        kept_lines.append(line)

    return "".join(kept_lines) if changed else None


# ---------------------------------------------------------------------------
# CSV — the Build 88 recipe export
# ---------------------------------------------------------------------------

CSV_HEADER = "library,id,title,cuisine,category,tags,source,created,remove"


def _csv_row_object(header: List[str], row: List[str]) -> Dict[str, Any]:
    obj: Dict[str, Any] = {}
    for index, name in enumerate(header):
        obj[name] = row[index] if index < len(row) else ""
    tags = obj.get("tags")
    if isinstance(tags, str) and tags:
        obj["tags"] = [part.strip() for part in tags.replace("|", ";").split(";") if part.strip()]
    return obj


def process_csv(path: str, result: FileResult) -> Optional[str]:
    try:
        with io.open(path, "r", encoding="utf-8", newline="") as handle:
            rows = list(csv.reader(handle))
    except (OSError, UnicodeDecodeError) as exc:
        result.error = "could not read: {}".format(exc)
        return None
    except csv.Error as exc:
        result.error = "not valid CSV: {}".format(exc)
        return None

    if not rows:
        return None

    header = [cell.strip().lstrip("﻿") for cell in rows[0]]
    lowered = [cell.lower() for cell in header]
    if "title" not in lowered:
        result.error = "no title column; not a recipe CSV"
        return None

    kept_rows: List[List[str]] = [rows[0]]
    changed = False

    for number, row in enumerate(rows[1:], start=2):
        if not any(cell.strip() for cell in row):
            continue
        obj = _csv_row_object(lowered, row)
        blocked, why = is_blocked_recipe(obj)
        if blocked:
            result.findings.append(Finding(result.path, "row {}".format(number),
                                           str(obj.get("title", "")), why, obj))
            changed = True
            continue
        result.kept += 1
        kept_rows.append(row)

    if not changed:
        return None

    buffer = io.StringIO()
    csv.writer(buffer, lineterminator="\n").writerows(kept_rows)
    return buffer.getvalue()


# ---------------------------------------------------------------------------
# Driving it
# ---------------------------------------------------------------------------

JSON_EXTENSIONS = (".json",)
NDJSON_EXTENSIONS = (".ndjson", ".jsonl")
CSV_EXTENSIONS = (".csv",)
ALL_EXTENSIONS = JSON_EXTENSIONS + NDJSON_EXTENSIONS + CSV_EXTENSIONS

SKIP_DIRS = {".git", "node_modules", "build", "DerivedData", ".build", "_purged",
             "Pods", ".venv", "venv", "__pycache__"}


def collect_files(targets: Iterable[str]) -> Tuple[List[str], List[str]]:
    """Return (files, missing_targets).

    Missing targets are handed back rather than merely warned about: a mistyped path in
    a CI gate that silently reports "nothing to do" is worse than no gate at all.
    """
    found: List[str] = []
    missing: List[str] = []
    for target in targets:
        if os.path.isfile(target):
            found.append(target)
            continue
        if not os.path.isdir(target):
            missing.append(target)
            print("  ! not found: {}".format(target), file=sys.stderr)
            continue
        for root, dirs, names in os.walk(target):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
            for name in sorted(names):
                if name.lower().endswith(ALL_EXTENSIONS):
                    found.append(os.path.join(root, name))
    return found, missing


def back_up(path: str, backup_dir: Optional[str]) -> str:
    if backup_dir:
        os.makedirs(backup_dir, exist_ok=True)
        destination = os.path.join(backup_dir, os.path.basename(path) + ".bak")
        suffix = 2
        while os.path.exists(destination):
            destination = os.path.join(backup_dir,
                                       "{}.{}.bak".format(os.path.basename(path), suffix))
            suffix += 1
    else:
        destination = path + ".bak"
        suffix = 2
        while os.path.exists(destination):
            destination = "{}.{}.bak".format(path, suffix)
            suffix += 1
    shutil.copy2(path, destination)
    return destination


def move_aside(path: str) -> str:
    folder = os.path.join(os.path.dirname(os.path.abspath(path)), "_purged")
    os.makedirs(folder, exist_ok=True)
    destination = os.path.join(folder, os.path.basename(path))
    suffix = 2
    while os.path.exists(destination):
        stem, extension = os.path.splitext(os.path.basename(path))
        destination = os.path.join(folder, "{}-{}{}".format(stem, suffix, extension))
        suffix += 1
    shutil.move(path, destination)
    return destination


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Remove Kaggle- and Sowens-sourced recipes from Stocked data files.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Dry run by default. Pass --apply to write. Originals are backed up first.")
    parser.add_argument("targets", nargs="+",
                        help="files or folders to scan (folders are walked)")
    parser.add_argument("--apply", action="store_true",
                        help="write the cleaned files (default is to report only)")
    parser.add_argument("--backup-dir", metavar="DIR",
                        help="put .bak copies here instead of beside the originals")
    parser.add_argument("--removal-csv", metavar="FILE",
                        help="list every blocked recipe found, in any format, as a "
                             "spreadsheet with the remove column set to yes, ready to "
                             "hand back to Stocked or Stocked for Mac")
    parser.add_argument("--move-seed-files", action="store_true",
                        help="move whole files whose NAME contains kaggle or sowens into a "
                             "_purged/ folder (needs --apply; nothing is unlinked)")
    parser.add_argument("--json-report", metavar="FILE",
                        help="write a machine-readable report")
    parser.add_argument("--quiet", action="store_true",
                        help="only print the totals")
    args = parser.parse_args(argv)

    files, missing = collect_files(args.targets)

    # Never scan our own output. The removal spreadsheet is an instruction file — every
    # row in it is a recipe we are removing, so a second pass would happily "purge" it
    # down to a header and hand the user an empty list. The JSON report and the backup
    # folder are excluded for the same reason: they are records of the sweep, not data
    # to be swept.
    self_made = set()
    for candidate in (args.removal_csv, args.json_report, args.backup_dir):
        if candidate:
            self_made.add(os.path.abspath(candidate))
    if self_made:
        def is_self_made(path: str) -> bool:
            full = os.path.abspath(path)
            return any(full == made or full.startswith(made + os.sep) for made in self_made)
        files = [p for p in files if not is_self_made(p)]

    if not files:
        print("Nothing to scan.")
        return 2 if missing else 0

    results: List[FileResult] = []
    had_error = bool(missing)

    for path in files:
        lowered = path.lower()
        if lowered.endswith(NDJSON_EXTENSIONS):
            kind = "ndjson"
        elif lowered.endswith(CSV_EXTENSIONS):
            kind = "csv"
        else:
            kind = "json"
        result = FileResult(path, kind)

        # Whole-file removal by name, before anything is parsed. A 40 MB Kaggle seed does
        # not need to be read line by line to know it should not ship.
        if args.move_seed_files and is_blocked_filename(path):
            result.findings.append(Finding(path, "(whole file)", os.path.basename(path),
                                           "filename matches a retired source"))
            if args.apply:
                try:
                    result.moved_to = move_aside(path)
                except OSError as exc:
                    result.error = "could not move: {}".format(exc)
                    had_error = True
            results.append(result)
            continue

        if kind == "ndjson":
            new_text = process_ndjson(path, result)
        elif kind == "csv":
            new_text = process_csv(path, result)
        else:
            new_text = process_json(path, result)

        if result.error:
            # A folder of mixed files will contain plenty of JSON that is not a recipe
            # file. That is not an error worth failing over — only report it when the file
            # was named like a recipe file or the user pointed straight at it.
            if len(files) == 1 or is_blocked_filename(path):
                had_error = True
            else:
                result.error = None
                continue

        if new_text is not None and args.apply:
            try:
                back_up(path, args.backup_dir)
                with io.open(path, "w", encoding="utf-8", newline="") as handle:
                    handle.write(new_text)
                result.rewritten = True
            except OSError as exc:
                result.error = "could not write: {}".format(exc)
                had_error = True

        results.append(result)

    # ----- report -------------------------------------------------------------

    touched = [r for r in results if r.removed or r.error]
    total_removed = sum(r.removed for r in results)

    if not args.quiet:
        for result in touched:
            marker = ""
            if result.moved_to:
                marker = "  -> moved to {}".format(os.path.relpath(result.moved_to))
            elif result.rewritten:
                marker = "  -> rewritten"
            elif result.removed:
                marker = "  -> dry run, not written"
            print("\n{}{}".format(result.path, marker))
            if result.error:
                print("    ! {}".format(result.error))
            for finding in result.findings:
                print(finding)

    print("")
    print("Scanned {} file(s).".format(len(files)))
    if total_removed == 0:
        print("No recipes from a retired source found. Nothing to do.")
    elif args.apply:
        print("Removed {} recipe(s) from {} file(s). Originals kept as .bak.".format(
            total_removed, len([r for r in results if r.rewritten or r.moved_to])))
    else:
        print("Found {} recipe(s) from a retired source in {} file(s).".format(
            total_removed, len([r for r in results if r.removed])))
        print("This was a dry run — nothing was changed. Re-run with --apply to remove them.")

    # One spreadsheet for the whole run, built from every finding in every format —
    # not one per CSV file. A JSON backup is the most likely thing to be scanned, and
    # its findings are exactly what the user needs in spreadsheet form to hand back to
    # the app. Whole-file matches (--move-seed-files) are skipped: there is no single
    # recipe to name, and the file has already been dealt with.
    if args.removal_csv:
        raw_rows = [f.csv_row() for r in results for f in r.findings
                    if f.where != "(whole file)"]
        # The same recipe often turns up twice — once in a JSON backup and again in a CSV
        # export of the same library. The app would handle the repeat harmlessly, but a
        # spreadsheet the user is meant to read should list each recipe once, and should
        # show the fullest version of it that any file had.
        best: Dict[Tuple[str, str], List[str]] = {}
        order: List[Tuple[str, str]] = []
        rows: List[List[str]] = []
        for row in raw_rows:
            identifier = row[1].strip().lower()
            if not identifier:
                rows.append(row)          # nothing to match on; keep it as its own line
                continue
            key = (row[0], identifier)
            filled = sum(1 for cell in row if cell.strip())
            if key not in best:
                best[key] = row
                order.append(key)
            elif filled > sum(1 for cell in best[key] if cell.strip()):
                best[key] = row
        rows = [best[key] for key in order] + rows

        if rows:
            try:
                with io.open(args.removal_csv, "w", encoding="utf-8", newline="") as handle:
                    writer = csv.writer(handle, lineterminator="\n")
                    writer.writerow(CSV_HEADER.split(","))
                    writer.writerows(rows)
                print("")
                print("Removal spreadsheet written to {} ({} row(s)).".format(
                    args.removal_csv, len(rows)))
                print("Hand it to Kitchen Transfer › Remove Recipes from CSV, or to")
                print("File › Remove recipes from a CSV on the Mac.")
            except OSError as exc:
                print("Could not write the removal CSV: {}".format(exc), file=sys.stderr)
                had_error = True
        else:
            print("")
            print("Nothing to put in a removal spreadsheet; {} not written.".format(
                args.removal_csv))

    if args.json_report:
        payload = {
            "scanned": len(files),
            "removed": total_removed,
            "applied": bool(args.apply),
            "files": [
                {
                    "path": r.path,
                    "kind": r.kind,
                    "removed": r.removed,
                    "kept": r.kept,
                    "rewritten": r.rewritten,
                    "movedTo": r.moved_to,
                    "error": r.error,
                    "findings": [f.as_dict() for f in r.findings],
                }
                for r in results if r.removed or r.error
            ],
        }
        try:
            with io.open(args.json_report, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2, ensure_ascii=False)
            print("Report written to {}".format(args.json_report))
        except OSError as exc:
            print("Could not write the report: {}".format(exc), file=sys.stderr)
            had_error = True

    if had_error:
        return 2
    if total_removed and not args.apply:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
