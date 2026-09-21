# Supported recipe export formats

Stocked owns these original Swift file readers; StockedMac vendors the same `KitchenArchive.swift`
and `KitchenMigration.swift`. No source, recipe collection or artwork from another kitchen app is
copied or bundled. There is no server login, upload, paid API, hosted AI or new dependency. System
zlib and ImageIO are supplied by Apple. Recipe authors retain their own rights independently of an
application's software license. Missing recipe licenses remain missing.

## Verified export shapes

| Export | Reader behavior | Producer reference |
| --- | --- | --- |
| Mealie recipe export | ZIP containing `recipes/<slug>/<slug>.json` and `images/original.*` beside each recipe; snake_case and camelCase ingredient/step records | [Exporter and schemas at 82387a2](https://github.com/mealie-recipes/mealie/tree/82387a281d6364b7e563bb9a93464eb662217193/mealie/services/exporter) |
| Tandoor default export | Outer ZIP containing a ZIP per recipe; each inner archive has `recipe.json` and its image. Ordered steps/ingredients, no-amount and heading flags retained | [Default exporter at e160cee](https://github.com/TandoorRecipes/recipes/blob/e160ceecaee0b269924be600a6d01ecb0bd55e30/cookbook/integration/default.py) |
| Paprika recipe export | `.paprikarecipes` ZIP with gzip-compressed JSON recipe entries, standalone gzip JSON, and bounded inline photo data. Also reads the legacy `recipes` JSON wrapper previously accepted by Kitchen Transfer | [Paprika export guide](https://www.paprikaapp.com/help/windows/); [Tandoor's maintained format adapter](https://github.com/TandoorRecipes/recipes/blob/e160ceecaee0b269924be600a6d01ecb0bd55e30/cookbook/integration/paprika.py) |
| Recipya Recipe JSON export | Schema.org Recipe JSON in per-recipe directories, with the recipe's specifically referenced photo filename in that directory | [File exporter at bbf4905](https://github.com/reaper47/recipya/blob/bbf490538b83851fd64a4b991d7638b135a7bef0/internal/services/files.go) |
| Open Recipe JSON | A Recipe object, an array of recognized recipes, or a bounded `@graph` of Recipe objects | [Schema.org Recipe](https://schema.org/Recipe) |

The table names tested formats, not all historical or future application versions. SQLite/database
backups, user settings, meal plans and arbitrary website/application exports are not restored as
recipes. Other versions should export Schema.org Recipe JSON or a smaller supported recipe archive.
Cooklang remains available in the existing recipe-file flow (and Mac multiple-file preview).

## Review, limits and compatibility

- Maximum 32 MiB input, 32 MiB cumulative expanded content, 500 total archive entries **including
  directories across nested archives**, 250 recipe candidates and 8 MiB per archive file.
  Tandoor's single nested archive layer is supported; deeper archives are rejected.
- Normalized Recipe JSON is at most 48 KiB per recipe. Original source text is retained only when
  it fits the existing private envelope, is exact UTF-8 entry text, and excludes embedded photos.
  Otherwise an original-export option is unavailable. The normalized preview is not called an original.
- JPEG/PNG original bytes are retained when their metadata is valid (one image, at most 40 million
  pixels, no edge above 16,384 pixels). Unsupported images are skipped with a warning and never
  converted to lower-quality copies. No remote photo is downloaded by the shared reader.
- Each platform also caps a multiple-file preview at 32 MiB. Review warnings identify omitted files,
  duplicate content, missing data and unsupported photos. Nothing is saved or published by parsing.
- Store additions are private by default. Original source URLs stay inside private `portableSource`;
  author, license and photo credits travel with the recipe. Mac public sharing needs an explicit rights
  choice, an original source and a valid photo. Existing Worker fields need no migration or deployment.
- App household transports impose smaller image/body limits. Large original photos stay local and
  in full backups; do not treat recipe synchronization as a guarantee that every original photo syncs.
- Unknown quantities, linked subrecipes and nutrition serving bases are not guessed. Producer labels
  are retained in notes where Stocked has no corresponding field. Review before relying on a migration.

## Validation

The archive suite uses Python's standard-library ZIP/gzip producers rather than the Swift reader
to construct fixtures. It checks corruption, CRC, unsafe names/links, duplicates, truncation,
compressed-size attacks, supported compression, exact bytes and cancellation.

From the Stocked repository, run `python3 scripts/test-kitchen-archive.py` (41 native checks).
Create migration fixtures with `python3 scripts/prepare-kitchen-migration-fixtures.py <temporary-folder>`,
then compile `Stocked/KitchenArchive.swift`, `Stocked/KitchenMigration.swift`, and
`scripts/KitchenMigrationChecks.swift` together using `xcrun swiftc`; run the resulting executable
with that folder as its argument (44 native checks). The iOS review safety suite separately checks
duplicates, source identity, concurrent-add rechecks and bounded undo history.

Fixtures are original small test data, not bundled recipes or personal files. These checks verify
specified export shapes and invariants; they do not replace testing with a user's actual export or
physical-device UI and household sync. Simulator testing remains paused.

## Source and license acknowledgements

The linked producer sources informed data interoperability only; none of their implementation is
copied. Their projects remain governed by their own licenses:
[Mealie AGPLv3](https://github.com/mealie-recipes/mealie/blob/82387a281d6364b7e563bb9a93464eb662217193/LICENSE),
[Tandoor AGPLv3 with Commons Clause](https://github.com/TandoorRecipes/recipes/blob/e160ceecaee0b269924be600a6d01ecb0bd55e30/LICENSE.md),
and [Recipya GPLv3](https://github.com/reaper47/recipya/blob/bbf490538b83851fd64a4b991d7638b135a7bef0/LICENSE).
Paprika Recipe Manager is proprietary; its name and documentation belong to its owner. See each app's
THIRD_PARTY_NOTICES and visible import/settings credits for ZIP, zlib, open formats and recipe rights.
