# Phases 1–6 acceptance contract

This file makes the performance/adaptability work recoverable and testable. A phase is complete
only when its implementation exists, its focused tests compile, the full Stocked test bundle
builds, and the generic iOS Simulator app build succeeds.

## Phase 1 — Baseline and measurable budgets

- The performance architecture and bounded-work rules are documented in
  `PERFORMANCE_ARCHITECTURE.md`.
- `PerformanceBudgetTests` covers the matching/parser hot paths and finite query budgets.
- CI builds the app and executes tests on both iPhone and iPad for every pushed branch and PR.

## Phase 2 — Adaptive UI foundation

- `DeviceAdaptiveRoot` injects live container, safe-area, Dynamic Type, and interface-scale data.
- `StockedLayoutMetrics` owns padding, control height, grids, navigation, and horizontal rails.
- The tab bar permits wrapped labels and maintains accessible touch targets.
- `AdaptiveUIFoundationTests` covers narrow, reference-phone, accessibility, safe-area, and iPad
  behavior.

## Phase 3 — Typed recipe mutations and real-time propagation

- `RecipeDatabaseChange` carries inserted, updated, and deleted values with a monotonic revision.
- `DatabaseSyncBus.recipeMutations` publishes replayable typed deltas.
- Batch writes persist and publish once; consumers can apply adjacent changes or request a snapshot
  after a revision gap.
- `RecipeDatabaseChangeTests` covers insert/update/delete, damaged duplicate input, and content-only
  updates.

## Phase 4 — High-impact screen constraint removal

- Home uses live layout metrics and reflows outside the approved reference-phone composition.
- Cook Later uses adaptive grids, wrapping controls, and accessible minimum targets.
- Recipes uses `ViewThatFits`, adaptive destination layouts, and container-scaled horizontal cards.
- Online recipe loading is bounded and its lists remain lazy/horizontally scrollable.

Fixed dimensions remain valid only for icons, separators, artwork aspect ratios, minimum touch
targets, and the explicitly approved reference-phone composition. They must not determine a
screen's overall width or prevent text from growing vertically.

## Phase 5 — Bounded persistence, corpus queries, and artwork repair

- The large bundled corpus remains read-only SQLite/FTS and is never decoded wholesale.
- All caller-supplied limits are clamped; discovery uses capped primary-key windows rather than
  `ORDER BY RANDOM()`.
- The content-addressed artwork overlay is bounded, durable, and prefers stable recipe identity.
- `LocalDatabase` exposes async reads and an explicit durability boundary.
- Performance tests cover query caps, sample budgets, async persistence, and overlay pruning.

## Phase 6 — Canonical remote sync, media, and ingestion

- Every writable ingestion path passes through title standardization, stable deduplication,
  blocklist checks, and image-reference validation.
- User and household image bytes are retained losslessly with container-independent references.
- Remote and retained artwork share `ImageCache`; invalid rows are quarantined with typed reasons.
- Batch ingestion, household sync, harvested sources, and offline caches converge on the same
  writable database and typed mutation stream.
- Tests cover lossless media retention, stable content references, corrupt/missing media,
  capitalization, blocked provenance, and image-less quarantine.

## Required release gates

1. `git diff --check`
2. Generic iOS Simulator Debug build
3. `build-for-testing` for the complete `StockedTests` target
4. Unit/performance execution on both an available iPhone and iPad simulator in CI

