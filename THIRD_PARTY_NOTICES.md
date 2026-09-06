# Third-Party Notices

The audited iOS application uses Apple system frameworks and original project modules; no separately packaged third-party runtime library requiring an additional open-source license notice was identified.

Stocked can interact with Apple, Cloudflare, Anthropic, TheMealDB, Spoonacular, USDA FoodData Central, Edamam, API Ninjas, RapidAPI providers, recipe publishers, and retailers. Those services, datasets, names, marks, and content belong to their respective owners and are subject to their terms. This notice must be regenerated if a third-party package or dataset is bundled in a release.

When enabled, Open Food Facts database records are available under the Open Database License (ODbL), individual database contents under the Database Contents License, and product images under the Creative Commons Attribution-ShareAlike terms specified by Open Food Facts. OpenStreetMap data is available under ODbL and must be attributed to OpenStreetMap contributors. See <https://openfoodfacts.github.io/documentation/docs/Product-Opener/api/tutorials/license-be-on-the-legal-side/> and <https://www.openstreetmap.org/copyright>.

## Free kitchen exchange — September 5, 2026

- **Cooklang Federation contributors:** https://github.com/cooklang/federation and
  https://recipes.cooklang.org. Stocked independently implements a read-only client of the
  documented search/detail HTTP API. The server repository uses GPLv3
  (https://github.com/cooklang/federation/blob/main/LICENSE); no server implementation, assets,
  database or GPL package is copied or bundled. Indexed recipes retain their own rights.
- **Grocy contributors:** https://grocy.info/ and
  https://github.com/grocy/grocy/blob/master/grocy.openapi.json. The optional connection is an
  independently implemented API client; Grocy code/data is not bundled. Project license: MIT,
  https://github.com/grocy/grocy/blob/master/LICENSE.
- **IETF CalDAV / WebDAV contributors:** RFC 4791 by Cyrus Daboo, Bernard Desruisseaux and
  Lisa Dusseault (https://www.rfc-editor.org/rfc/rfc4791.html); RFC 4918 edited by Lisa Dusseault
  (https://www.rfc-editor.org/rfc/rfc4918.html); iCalendar RFC 5545 edited by Bernard Desruisseaux
  (https://www.rfc-editor.org/rfc/rfc5545.html). Original clients use Apple Foundation, URLSession,
  XMLParser and Security/Keychain without copied protocol implementation code or a new package.

- **PKWARE:** ZIP format specification 6.3.10, https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT.
  The bounded archive reader is original Stocked code, not specification text or third-party parser
  code. It supports stored/Deflate ZIP and excludes encryption, ZIP64 and proprietary extensions.
- **Jean-loup Gailly and Mark Adler / zlib:** archive inflation uses Apple's system-provided zlib,
  https://zlib.net/zlib_license.html. No separate copy of zlib is bundled or modified by this change.

- **Cooklang contributors:** https://cooklang.org/docs/spec/ and https://github.com/cooklang/spec.
  Stocked's bounded parser/exporter is independently implemented against a supported subset of
  the Cooklang format; it does not bundle a Cooklang parser or copy its source. Original imported
  files retain their own authorship, comments and metadata. The specification repository uses MIT.
- **Schema.org contributors:** https://schema.org/Recipe. Recipe JSON/JSON-LD exchange uses this
  vocabulary through original app code. The vocabulary does not license publisher recipes or photos.
- **IETF / Bernard Desruisseaux and RFC 5545 contributors:** https://www.rfc-editor.org/rfc/rfc5545.
  Calendar export is an original implementation of the iCalendar format, not extracted RFC code.
- **Open Prices / Open Food Facts contributors:** https://github.com/openfoodfacts/open-prices/blob/main/API.md.
  Community prices use ODbL 1.0: https://opendatacommons.org/licenses/odbl/1-0/.
  Location metadata credits © OpenStreetMap contributors: https://www.openstreetmap.org/copyright.
  The feature retrieves observations explicitly, displays attribution next to them, and does not
  combine this dataset into the proprietary personal-price database. No proof/receipt images are used.
- **USDA Agricultural Research Service, FoodData Central:** https://fdc.nal.usda.gov/api-guide/.
  Existing optional nutrition data is public domain / CC0; retain the food identifier and source.
- **Design inspiration, no application code reused:** Mealie (https://docs.mealie.io), Tandoor
  Recipes (https://github.com/TandoorRecipes/recipes), KitchenOwl (https://docs.kitchenowl.org/latest/),
  Grocy (https://github.com/grocy/grocy). These projects are independently maintained; their licenses
  do not apply to Stocked's original implementations, and no affiliation or endorsement is implied.

Publisher author, source URL, license and photo-credit fields supplied with an import must travel
with exported/published recipes. A missing license stays missing; do not assume that public access
or successful extraction grants redistribution rights. Raw imported files are household-private.

The new tools add no runtime library or hosted AI requirement. A future copied dependency must add
its complete required copyright/license text here and in the distributed application before release.

Last reviewed: September 5, 2026.

## Recipe export compatibility

Mealie, Tandoor Recipes, Paprika Recipe Manager and Recipya are acknowledged in the app's Sources &
Credits screen. `KITCHEN_MIGRATION_FORMATS.md` records supported export shapes and pinned producer
references. The original Swift adapters do not bundle those applications' code or assets.
Mealie's referenced source is AGPLv3, Tandoor's is AGPLv3 with Commons Clause, and Recipya's is GPLv3;
Paprika is proprietary. These application licenses do not supply rights to users' recipes or photos.
No new copied dependency or packaged server is introduced. Each imported author's supplied credits,
license and publisher information remain with the recipe; public sharing still needs permission.
