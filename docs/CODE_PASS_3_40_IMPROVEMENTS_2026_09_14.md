# Stocked iOS — third code pass

September 14, 2026. **40 new code improvements** in response caching, container-quantity input and local correction calibration. This ledger does not recount the Kitchen Math features or the second pass's timers, unit conversion and reminders. Tests and documentation are evidence, not additional improvements. Previous dirty work remains intact.

## Exact change ledger

| # | Concrete correction | Source evidence |
|---|---|---|
| C01 | Response identities use length-framed SHA-256 parts. Binary payload boundaries and separator characters cannot ambiguously concatenate into the same request identity; the former small custom hashes are retired. | `Stocked/ResponseCacheStorage.swift` — `ResponseCacheKey`; `AIResultCache.key`; `SmartResponseCache.key` |
| C02 | Smart cache identities include the decoded response type, so two models using the same endpoint/arguments do not consume each other's response. | `Stocked/SmartResponseCache.swift` — `SmartCached.value` |
| C03 | API cache namespaces are bounded and path-safe; request keys become fixed hexadecimal filenames. A namespace or request containing `../` cannot choose another cache folder/file. | `Stocked/Nutrition/APIResponseCache.swift` — `init`; `ResponseCacheStorage.file` |
| C04 | Each cache's memory dictionary has an independent entry-count ceiling; inserting a new entry evicts the least recently accessed entry, and replacing an existing entry does not evict an unrelated peer. | `ResponseCacheStorage.retain/removeMemory`, `Limits.entries` |
| C05 | Memory retention also has a byte ceiling, independent of entry count. A few large responses can no longer occupy unbounded cached memory. | `ResponseCacheStorage.memoryBytes/retain`, per-wrapper limits |
| C06 | Cached payload writes reject empty/oversized entries before encoding the disk envelope or retaining them. This bounds cache work without altering the original network response delivered to its caller. | `ResponseCacheStorage.store`, `Limits.entryBytes` |
| C07 | Disk reads check metadata size and then read at most the encoded limit plus one byte. A corrupt or growing file cannot trigger an unbounded `Data(contentsOf:)` cache load. | `ResponseCacheStorage.lookup` |
| C08 | Lookup, maintenance and Clear inspect only recognized regular cache files; symlinks, nested folders and foreign filenames are left alone. Clear no longer recursively deletes a cache directory. | `ResponseCacheStorage.ownedRegularFile/files/clear` |
| C09 | TTLs must be finite and positive and are capped at one year. Zero/nonfinite TTL invalidates the previous answer instead of accidentally retaining it indefinitely. | `ResponseCacheStorage.store`, bounded `Limits.maximumTTL` |
| C10 | Stored timestamps and expiry intervals are validated independently of last access. Far-future timestamps, impossible expiry, elapsed expiry and nonfinite dates fail closed; touching an entry does not extend its freshness. | `ResponseCacheStorage.valid/lookup/store` |
| C11 | Every disk write recreates the cache directory when necessary. An OS-purged cache can refill during the same app session; disk-write failure still leaves a valid fetched answer available in memory. | `ResponseCacheStorage.store` |
| C12 | Disk-byte pruning runs immediately after successful writes, rather than allowing responses to grow until a separate maintenance action. | `ResponseCacheStorage.store/prune`, per-wrapper disk budgets |
| C13 | A separate disk-file-count budget bounds many small entries even when their total size is low. | `ResponseCacheStorage.prune`, `Limits.entries` |
| C14 | Reads update recency, and equal timestamps use stable filename ordering. Frequently used responses are protected from write-only eviction behavior. | `ResponseCacheStorage.lookup/touch/prune` |
| C15 | Pruning subtracts a file from its remaining byte/count budget only after deletion succeeds. A failed deletion no longer makes the cache believe it reached its target. | `ResponseCacheStorage.prune` |
| C16 | Invalid envelope versions, wrong request identities, malformed JSON and model decode failures evict the bad entry instead of repeating the same poisoned hit on every request. | `ResponseCacheStorage.lookup/valid`; `APIResponseCache.value`; `SmartCached.value` |
| C17 | AI requests capture the cache generation before fetching and supply it when saving. An answer from a request started before Clear cannot refill the cleared AI result cache. | `Stocked/StockedWorkerClient.swift` — `performRequest`; `AIResultCache.currentGeneration/save` |
| C18 | Concurrent cold Smart requests share one producer. Starting a producer rechecks the cache, closing the late-join race after another request has just completed. | `SmartResponseCache.flight/refreshedData` |
| C19 | Stale Smart responses remain immediately available while all callers share one background refresh, instead of each stale lookup issuing another request. | `SmartCached.value`; `SmartResponseCache.refreshInBackground/flight` |
| C20 | Smart refresh tasks have UUID ownership and generation checks. Clear cancels owned work and rejects retired publication; canceling one waiter suppresses its result without canceling the producer needed by another waiter. | `SmartResponseCache.complete/clear/refreshedData` |
| C21 | Failed Smart refreshes have a 30-second monotonic cooldown with at most 256 remembered failures; at most 32 producers can be active. Repeated failed lookups cannot create unlimited refresh work. | `SmartResponseCache.retryAfter/flight/complete` |
| C22 | Data & Storage includes Smart response bytes and clears that cache in its existing Clear All action. Reported/cleared AI storage now includes both AI response paths. | `Stocked/DataStorageView.swift` — `CacheMaintenance.usage/clearAll` |
| C23 | Invalid negative, nonfinite, excessive or zero-denominator quantities produce explicit validation state. Signed Unicode fractions retain their minus (`-0½`, `−¼`) and are rejected. Both quantity fields preserve their previous value on error; package-size editing applies the same finite bounds. | `Stocked/QuantityParser.swift` — `parse/number/invalid`; `Stocked/QuantityInputView.swift` — both `apply` methods and amount binding |
| C24 | Quantity formatting never converts an unchecked `Double` to `Int`. Nonfinite values display a placeholder and extreme finite values use bounded significant-digit formatting. | `ParsedAmount.trim` |
| C25 | Articles qualify fractional quantities rather than adding a whole item: `half a bag` and `a half bag` both produce 0.5. | `QuantityParser.leadingNumber` |
| C26 | Dozen phrases multiply the leading quantity: `a dozen` → 12, `two dozen` → 24, `half a dozen` → 6. | `QuantityParser.parse` |
| C27 | Mixed/slash/Unicode fractions and explicit conjunctions are evaluated mathematically; `1½`, `2 1/4`, and `one and a half` work. Unrelated adjacent integers are not silently added. | `QuantityParser.leadingNumber/number` |
| C28 | Only a leading quantity and an explicitly recognized package size change numeric state. In `2 bags 3 musketeers`, the later `3 musketeers` stays product text; standalone `3 musketeers` is parsed as three items. `7up` remains product text, not a quantity. | `QuantityParser.parse/looksNumeric` |
| C29 | `fl oz`, `fl. oz.` and `fluid ounces` are consumed as one measurement, preserving fluid-volume units rather than misreading `fl` as item text. | `QuantityParser.measure` |
| C30 | Count, container and each-size remain separate for both `6 cans of 8 oz` and `6 cans 8 oz`. The generated `· … each` summary can be parsed back without losing the package size. | `QuantityParser.parse`; `ParsedAmount.display` |
| C31 | Explicit container aliases replace destructive suffix trimming: `cases` becomes `case`, `loaves` becomes `loaf`. Display preserves invariant unit abbreviations such as `oz` and correct irregular plurals. | `QuantityParser.containerAliases/plural` |
| C32 | Numeric grouping and decimal commas are distinguished: `1,000` is one thousand while `0,5` is one half. Grouped input is no longer fragmented into extra quantities. | `QuantityParser.number` |
| C33 | Natural quantity input is bounded to 4,096 characters before lowercasing/token arrays. Oversized input is rejected explicitly, rather than silently parsing a truncated amount or doing unbounded work. | `QuantityParser.maximumCharacters/parse` |
| C34 | Restored correction history is bounded to a 1 MiB encoded payload, 250 validated records and 512-character texts. Malformed keys, invalid timestamps and oversized values are excluded in memory without rewriting data on launch. | `Stocked/AICorrectionStore.swift` — `init`; new `Stocked/CorrectionCalibration.swift` — `init/repaired/text` |
| C35 | Restored counters are clamped, new increments saturate at one million, and ratio aggregation uses `Double`. Negative or maximum-integer history cannot overflow scoring. | `CorrectionCalibration.repaired/record/confidence` |
| C36 | Evidence is reset when the predicted/final correction pair changes. Earlier approvals of a different answer no longer endorse the new answer under the same original input. | `CorrectionCalibration.record` |
| C37 | Confidence adjustment requires the current predicted value to match the recorded prediction. Merely sharing the original item text no longer grants unrelated predictions a confidence boost. | `CorrectionCalibration.confidence` |
| C38 | Base confidence is finite and clamped even when no matching history exists. NaN/infinity and out-of-range values cannot propagate to confidence consumers. | `CorrectionCalibration.confidence`; `AICorrectionStore.adjustedConfidence` |
| C39 | Conflicting prompt corrections are ranked deterministically by evidence, rejection count, recency and stable key; one normalized prediction gets one correction. Negative/large requested output limits are safely bounded. | `CorrectionCalibration.promptCorrections` |
| C40 | Item-name prompt corrections exclude zone, expiry and quantity history, plus unchanged names. A zone correction can no longer be injected as a replacement food name. | `CorrectionCalibration.promptCorrections` |

## Ownership, compatibility and recovery

Stocked iOS owns this batch. AIResultCache, APIResponseCache and SmartResponseCache actors own their respective ResponseCacheStorage value; none is called from a SwiftUI body. Existing Worker, nutrition and Smart callers remain the response producers. Data & Storage is a maintenance consumer. The Worker client change supplies local cache-generation metadata only; no route, authentication, model/provider choice, response contract or household schema changes.

Existing cache namespaces remain, with new `v2_<digest>.json` files containing their request identity. Legacy cache envelopes do not contain enough information to prove their full original request identity, so they deliberately cold-miss once after this update. Recognized legacy filenames remain included in owned maintenance budgets and Clear. The original recipes, inventory, groceries, household records, provider credentials and source files are never cache-migration inputs. Normal requests can refill caches; no request was made during these checks. An offline device may initially lack an old cached response until it reconnects. Cache failure remains best effort, and upstream network body limits are unchanged by this pass.

`ParsedAmount.validationMessage` is optional and additive; old encoded amounts without it still decode. Existing successful parse fields remain the same. Invalid natural input does not commit to the host, and the host's authoritative inventory/grocery mutation paths are unchanged. The parser supports the documented English container/fraction grammar, not arbitrary natural language, numeric ranges or every locale convention. Comma interpretation is explicit above; no density or mass/volume conversion is inferred.

Correction history keeps the existing `aiCorrectionCalibration_v1` UserDefaults key and the existing Codable record fields. Loading repairs a bounded in-memory copy only. A subsequent explicit user correction persists the bounded history. An oversized legacy blob is ignored for calibration without deleting the saved blob on launch. Prompt output remains a name-correction dictionary, not a new shared schema or automatic kitchen-record rewrite.

Rollout is an app update. No server migration, service deployment, network credential or separate Mac change is required. No simulator, device installation, production cache clear or live user-data mutation was performed.

## Verification

Native checks use disposable UUID-named temporary directories and controlled clocks; they never read or modify app caches or UserDefaults.

- **117 new response/data reliability checks passed.** Coverage includes framed/typed identities, count/byte bounds, corrupt/oversized files, safe clear and directory recovery, impossible dates, typed decode failure, shared cold/stale requests, cancellation and clear races, retry cooldown, legacy quantity decoding, invalid package amounts, signed Unicode fractions/dozens/product-name preservation and bounded calibration conflicts/counters.
- **89 cooking reliability regression checks passed**, preserving the earlier timer, unit and reminder work. Total executed native checks in this final batch: **206**.
- Final generic iOS build **succeeded**, with no reported compiler warnings/errors. The app, share extension and widget all contain marketing version **5**, build **250**.
- `git diff --check` passed. The numbered ledger contains exactly 40 code corrections.
- Independent read-only review of the cache lifecycle, Worker save path and calibration arithmetic found no blocking issue. No files were changed by that reviewer.

```sh
xcrun swiftc -parse-as-library Stocked/ResponseCacheStorage.swift Stocked/AIResultCache.swift Stocked/Nutrition/APIResponseCache.swift Stocked/SmartResponseCache.swift Stocked/QuantityParser.swift Stocked/CorrectionCalibration.swift scripts/ResponseDataReliabilityChecks.swift -o /tmp/stocked-response-data-checks
/tmp/stocked-response-data-checks
```

Generic build cache: `/Volumes/Macintosh SSD/MacStorage/Developer/DerivedData/Stocked-Polish-20260914`. Final build log: `/tmp/stocked-code-pass3-final-build.log`.

Device UI, memory-pressure behavior, actual notification delivery and live provider responses are not verified by pure-logic checks or generic compilation. File-delete failures are handled conservatively but not forced in a read-only-volume fixture; best-effort maintenance cannot guarantee reclaiming files the OS refuses to delete.
