# Cooklang community connections

**iOS:** Recipe Files → Explore Cooklang community recipes, or Settings → Data & Storage → Free Kitchen Connections → Find Cooklang recipes.
**Mac:** File → Import Center → Explore Cooklang community recipes.

Search the free Cooklang Federation index, read a recipe, then choose **Review private import**.
Existing import review shows content, credits, parser warnings and saved duplicates. iOS continues
to the editable recipe form; final save rechecks current household permissions and duplicates,
including recipes another device added while the editor was open. Explicit separate-copy consent
covers only the duplicate records shown at review. Existing recipes are never overwritten.

Mac uses existing portable-recipe review, duplicate checks, photo validation and unchanged-addition
undo. Its current photo requirement remains. A recipe without a usable photo cannot be saved on
Mac; export and edit its Cooklang file or use iOS's private text-only support. Mac fetches recipe
photos only after explicit import, through its existing validation path. Search never downloads
publisher pages or photos.

## Exact supported protocol

This is a client of **Cooklang Federation**, not a generic RSS reader or the different CookCLI
local-server API. The default address is `https://recipes.cooklang.org`. A device may save one
alternative public HTTPS address implementing the same API, including a reverse-proxy path prefix.
Local HTTP servers, embedded credentials, custom ports, redirects and authentication are unsupported.
No cloud login, paid API account, hosted AI or paid fallback is added.

- Search: `GET /api/search?q=…&page=…&limit=20`, reading `results` and `pagination`.
- Recipe: `GET /api/recipes/:id`, reading indexed Cooklang `content` and source/feed metadata.
- [Official API reference](https://github.com/cooklang/federation#api-endpoints).
- [Official wire models](https://github.com/cooklang/federation/blob/main/src/api/models.rs).
- [Federation draft publishing specification](https://github.com/cooklang/federation/blob/main/spec.md).

The Federation server handles RSS/Atom/Git-hosted discovery. Stocked never registers a feed,
publishes recipes, crawls publishers or runs an indexer. A read-only live probe on September 5, 2026
verified the official HTTPS search and matching recipe detail without credentials. No probe recipe
was saved. Availability is optional: errors preserve prior loaded results and every saved recipe.
Counts say **loaded**, not a claim about the index's complete total.

## Bounds and privacy

One request runs at a time. One page of up to 20 rows is kept; navigation stops at page 10.
Queries are limited to 200 characters, JSON to 256 KiB and source text to 48 KiB, plus existing
escaped-text/provenance limits. Streaming stops at the byte cap or a 25-second resource timeout.
Cancellation invalidates network work and rejects late results. Parsing runs off the main actor.
There is no background refresh, result database, cookie sharing or account credential storage.

Search sends only typed words and pagination to the chosen index. Its address is a small device-local
preference, not a household secret. Public HTTPS validation excludes literal/local addresses and
embedded credentials; it is not a DNS firewall. Redirects are refused before another host is contacted.

The indexed text stays exact in the existing private `portableSource` envelope. Recipe-declared
author/license/source wins; collection curators are credited separately in private notes, never
invented as recipe authors. Index content may be stale, so review original sources and rights.
Top-level legacy `sourceURL` stays empty, the original link stays in private provenance, and
catalogue sharing stays false. This connection never approves public publication or sends raw
source/notes into harvest. Existing Worker old-client privacy preservation continues to apply.

## Verification

```sh
xcrun swiftc Stocked/CooklangFederation.swift scripts/CooklangFederationChecks.swift -o /tmp/stocked-cooklang-federation
/tmp/stocked-cooklang-federation
# Optional two-request public probe, without saving recipes:
/tmp/stocked-cooklang-federation --live
xcrun swiftc Stocked/RecipeMigrationSafety.swift Stocked/RecipeImportCommitPolicy.swift scripts/RecipeImportCommitChecks.swift -o /tmp/stocked-import-commit
/tmp/stocked-import-commit
```

The 29 deterministic protocol checks cover endpoint/query boundaries, page and recipe identity,
duplicates, response/text limits, exact source retention, invalid URLs, missing content and
cancellation. One optional live check verifies official service compatibility. Six commit checks
cover prior duplicate consent, concurrent additions and revoked permission. Builds/native checks
do not verify device UI, VoiceOver or actual household synchronization.

Stocked iOS owns the identical `CooklangFederation.swift` and `CooklangConnectionPanel.swift`
copies mirrored into StockedMac. No new Worker route, household field or dependency is required.
This is original client code against a public interface. No GPL Federation server code is copied
or linked. Cooklang contributors and recipe owners are credited in-app and in third-party notices;
the server license does not grant rights to republish indexed recipes.
