# Stocked sync and Worker reliability — September 5, 2026

This batch preserves local-first storage, the durable outbound household journal, protocol-v1/v2
responses, receipt semantics, KV key names, and the transferred HouseholdDO namespace. No production
deployment or data migration was performed.

## Ten implementation improvements

1. Worker JSON request limits now stop at the real streamed UTF-8 byte budget, cancel oversized
   bodies, and correctly handle Unicode split across network chunks.
2. Daily-brief context writes validate object shape/arrays/scalars before persistence and preserve
   an explicitly selected zero-day horizon instead of replacing it with seven days.
3. Brief assembly tolerates malformed legacy rows, bounds the planning horizon, ignores future
   added-at timestamps, and flags already-expired items for review rather than recommending use.
4. Scheduled briefs traverse all KV pages, with 100 keys per page and at most four concurrent
   context reads; a repeated/nonadvancing cursor fails explicitly.
5. Cron skips missing, malformed, expired, oversized, or wrong-household contexts, continues healthy
   siblings, and reports partial enqueue failures instead of claiming success.
6. Queue jobs acknowledge only after a successful storage write; missing/broken storage retries.
   Invalid or expired jobs are deliberately discarded without replacing an existing brief.
7. Brief telemetry no longer includes invitation codes or raw exception strings.
8. Shared iOS GET retries stop on cancellation (including cancelled sleeps/URLSession requests),
   check connectivity between attempts, and retry only transient transport failures.
9. One retry policy safely parses seconds/HTTP dates, rejects unsafe numeric values, respects
   503 Retry-After, and ends foreground retries rather than shortening a long server cooldown.
10. Household retries preserve server minimum delays despite jitter, recognize URLSession
    cancellation, decode response JSON off-main, and reject malformed successful responses without
    claiming success or discarding local work.

## Ownership and compatibility

- Owner: UnifiedWorker for request/brief transport, scheduling, KV persistence and queue semantics;
  Stocked iOS for local queue state, retry policy and response application.
- Producers: Stocked iOS/StockedMac/older released brief callers, the scheduled Worker and Queue.
- Consumers: existing Stocked iOS/Mac clients, household sync diagnostics, brief readers and operators.
- Rollout: validate/deploy UnifiedWorker first, smoke-test context/queue/household endpoints, then
  release the Stocked client. Both sides remain independently compatible with the old other side.
- Fallback: prior released client/Worker code and unchanged data schemas; no destructive repair,
  rejoin, code rotation, namespace recreation, or reset. Existing valid brief contexts are accepted
  without a timestamp; newly persisted snapshots include the existing storedAt field.
- Repair: invalid/expired brief jobs leave the last valid brief untouched and stop poisoning the
  queue. A new valid context naturally replaces them. The durable client journal remains queued on
  cancellation, rate limit, malformed response, or transport failure.

## Verification

UnifiedWorker: `npm test` — 104 tests passed, including 14 new byte-budget/brief queue/cron tests;
`npm run typecheck` passed; `npm run check` production dry-run bundle passed. Its existing Wrangler
experimental `unsafe` binding warning remains unchanged. No remote deployment occurred.

Stocked: native production-code harness passed 18 checks without network requests or a simulator:

```sh
xcrun swiftc -parse-as-library Stocked/NetworkRetry.swift scripts/NetworkRetryChecks.swift -o /tmp/stocked-network-checks.crwztD/checks
/tmp/stocked-network-checks.crwztD/checks
```

The parent task owns final generic-device compilation and on-device QA. Native checks do not verify
the UI, household races on real devices, Cloudflare production queue delivery, or deployment health.
