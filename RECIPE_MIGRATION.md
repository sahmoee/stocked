# Reviewed recipe collection imports

Open **Recipes → Add Recipe → Import or export recipe files → Bring recipes from another app**.
Select supported Mealie, Tandoor, Paprika or Recipya exports, or several recipe JSON files. Importing
is local and does not need a paid API, AI service or another account login.

1. Review the parsed collection. Duplicates against saved recipes and within the selected files
   start unselected. Warnings identify missing fields, rejected files and partial previews.
2. Open **Review ingredients, steps and credits** to use the existing recipe editor. **Use changes**
   only updates the pending candidate. Unknown or ambiguous servings require this review before selection.
3. Confirm **Save selected recipes**. The normal recipe permission is checked for each addition.
   The importer saves one recipe at a time, rechecks duplicates, and never replaces an existing record.
4. **Stop here** keeps completed additions. Reopening the same supported export skips saved records
   so an interrupted batch can continue. Imports above the preview limits need smaller exports.
5. During this visit, **Undo recent unchanged imports** covers the newest 250 additions and removes
   only records still identical to their stamped imported versions. Older imports, subsequent edits,
   cooking history and unrelated recipes remain. Reading another file does not reset this bounded history.

All bulk additions are private. The original publisher URL lives in optional
`portableSource.originalSourceURL`, while the public top-level `sourceURL` stays empty. That also
protects against older clients' automatic publication rules. Modern household normalization retains
omitted private provenance on legacy edits. Nothing is published to the public recipe catalogue.

Local JPEG/PNG photo bytes remain local and in backups. Household transports have smaller image and
body limits; photos above 180 KB may not reach every client. The preview calls this out. No image is
downloaded during archive parsing. Files with no photo can still become private text recipes.

The list is a normalized recipe preview. An available preserved original is the UTF-8 recipe entry,
including an extracted/decompressed entry where applicable, and is labelled **Imported source text**.
The ZIP or gzip container is not represented as an exact original recipe file. When the source entry
cannot safely be retained, original export is unavailable rather than replaced by a fabricated file.
Creator, license, photo attribution, source notes, total time and original yield are retained when
supplied. Supplied nutrition is kept as labelled source notes rather than silently recalculated.

## Limits and ownership

The shared `KitchenArchive` reader owns archive safety and `KitchenMigration` owns tested export-shape
normalization. iOS and Mac carry compatible copies. `RecipeMigrationReview` owns iOS review, duplicate
rechecks and commit/undo behavior; `GuestDataStore` remains the authoritative personal/household store.
There is no new Worker route, database, paid dependency or public recipe schema for this batch.

iOS reads at most 20 selected files and retains at most 250 recipe candidates and 32 MiB of preview
data including photos, decoded fields and preserved source text. Every normalized recipe is at most
48 KiB. Oversized, unsupported, malformed or encrypted input produces an actionable warning; archive
paths never become extraction destinations. Existing Stocked backups continue through Kitchen Transfer.
Legacy Paprika transfer now directs to this reviewed path and cannot blindly replace a collection.

## Verification

`scripts/RecipeMigrationSafetyChecks.swift` exercises saved/in-batch duplicates, URL identity,
commit rechecks and conservative undo eligibility without a simulator. The shared archive and
migration suites cover accepted/rejected file shapes. A generic-device build validates iOS integration.
QA section 50 adds eleven untested device checks. Compilation and native logic checks do not establish
device UI, VoiceOver or live household-sync passes; simulator testing remains paused.
