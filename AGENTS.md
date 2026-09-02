# Unified AI, build, and cross-project instructions

This is the single authoritative instruction contract for Codex, Claude, and any other AI or build agent in this repository. Read `README_FIRST.md` first, then read only the sections below that match the current project and task. Legacy instruction filenames link here; do not duplicate rules into them.

## Task routing and updates

1. Identify the current repository and feature boundary before reading or editing code.
2. For UI work, read Product and UI rules; for data/API work, also read Cross-project ownership; for QA tickets, also read QA; for build/release work, also read Validation and publishing.
3. Inspect repository status and preserve unrelated changes. Search for existing implementations and tests before adding another path.
4. Load secrets only from ignored machine-local configuration or Keychain. Never copy values into source, prompts, logs, screenshots, fixtures, or documentation.
5. Default every metered AI request to the lowest-credit supported model and prefer on-device AI when it can satisfy the task. Preserve explicit user/operator model overrides; do not silently promote a default request to a costlier model.
6. When behavior, setup, compatibility, ownership, or validation changes, update the relevant section here and the concise project facts in `README_FIRST.md` in the same verified batch.
7. Shared changes must name an owner, producers, consumers, rollout order, fallback, migration/repair behavior, and verification matrix before publication.
8. Read narrowly to minimize tokens, but never skip a section selected by these routing rules.

## Project and UI rules



Every page, sheet, popover, and cover must fill its presentation with the active Stocked theme, never the stock white host background. Layouts and controls must adapt to available window width, device class, orientation, Split View/Stage Manager, safe areas, and Dynamic Type. Prefer flexible frames, adaptive grids, `ViewThatFits`, and minimum hit targets; fixed dimensions are reserved for intentional artwork/media geometry. Do not force scrolling when content fits or disable scrolling needed by smaller screens or accessibility text.

App-level headers and root tab bars have one shared implementation and one geometry source. Feature pages must not locally override brand placement, chrome height, safe-area spacing, icon slots, labels, or selected-tab geometry.

## Cross-project ownership and synchronization


- `StockedMac`: creates/edits/imports the shared image-complete recipe library.
- `UnifiedWorker`: AI, household, recipe/harvest content, QA, queues, and compatibility routes.
- `site-repo`: public product pages and content feeds.

Recipe schemas, images, provenance, categories, household data, QA, or API changes require compatible updates across affected repos. Keep old records and released clients working; make fields additive and repairs retroactive.
Source-attributed, image-complete imports publish to UnifiedWorker's shared harvest catalogue even
when the device is not in a household. Preserve publisher name, canonical URL, and original image
URL; source-less personal recipes may remain household-scoped.

Stocked QA uses the shared `Joo` ten-minute gate. Once unlocked, sync first merges the app-scoped Worker ticket collection from every iPhone/iPad, then publishes local changes. Mac apps do not expose in-app QA.

## QA

Background invariant classification uses bounded yielding batches; interrupted or revision-stale
snapshots must not be reported as a clean QA run. Harvest JSON conversion stays off the main actor,
and bulk publication uses one coalesced, bounded worker rather than per-recipe tasks.

“Check tickets” means pull the complete cross-device Stocked QA collection, fix every actionable open ticket in the same task, validate the affected iPhone and iPad targets, add a shipped resolution, and publish the fixed ticket state. A read-only summary is not completion. Never mark a ticket fixed when validation fails; `verified` remains a tester/device action after the corrected build is exercised.

UnifiedWorker owns Kroger OAuth and RapidAPI host allowlisting. StockedMac discovers and publishes normalized grocery catalog records; Stocked iOS finds provider-backed stores and consumes normalized product data. Never add provider secrets to iOS, and keep store-specific price/availability/aisle caches bounded so stale data cannot replace user-confirmed inventory.

## Shared safety, validation, and publishing contract


### Project intake

1. Begin with the named entry point and expand scope only when evidence requires it.
2. State the feature boundary before editing so adjacent shipped behavior is preserved.
3. Identify the authoritative local, server, and generated data sources before changing models.
4. Keep credentials, signing material, user data, and machine-local configuration outside commits.
5. Treat released schemas, URLs, deep links, persistence formats, and extension contracts as compatibility surfaces.
6. Preserve offline/local-first behavior and provide a recoverable failure path for optional services.
7. Apply the complete product theme, adaptive layout, Dynamic Type, accessibility, and device-size contract to UI work.
8. Prefer migrations and retroactive repair over destructive replacement of existing records.
9. Run the narrowest meaningful validation first, then every affected target or consumer.
10. Finish only when behavior, setup, verification, documentation, and cross-project impact agree.

### Implementation and verification

1. Inspect repository status first and preserve unrelated user or agent work.
2. Make the smallest coherent batch that resolves the root cause without silently dropping features.
3. Search for existing abstractions, tests, and generated sources before adding parallel implementations.
4. Never expose secrets in code, logs, screenshots, fixtures, commits, or implementation briefs.
5. Keep public and persisted changes additive unless an explicit, tested migration removes the old path.
6. Update all affected app, widget, extension, Worker, site, and tooling consumers in the same coordinated task.
7. Test empty, loading, failure, offline, cancellation, retry, duplicate, and accessibility states when relevant.
8. Do not publish, deploy, migrate production data, or mark QA resolved after failed validation.
9. Record material decisions and new invariants in the existing short guides without duplicating large documentation.
10. Hand off with changed files, validation evidence, deferred risks, and any required operator action.

### Cross-project delivery

1. Name one owning repository for every shared schema, route, asset, or generated artifact.
2. List every producer and consumer before modifying a shared contract.
3. Preserve older clients with additive fields, tolerant decoding, stable URLs, and routing shims where required.
4. Define rollout order so providers remain compatible before consumers adopt new behavior.
5. Make migrations idempotent, resumable, observable, and safe to retry after interruption.
6. Keep secrets server-side or machine-local and synchronize only names, requirements, and validation—not values.
7. Propagate fixes retroactively to stored records when the invariant applies to old and new data.
8. Validate a matrix covering the owner, direct consumers, extensions/widgets, public content, and fallback paths.
9. Update README-first, AI instructions, cross-project sync, and public documentation in the same verified batch.
10. Retain a rollback or compatibility path until deployed clients and persisted data confirm the new contract.
