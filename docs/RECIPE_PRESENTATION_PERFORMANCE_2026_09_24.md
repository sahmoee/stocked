# Recipe presentation and Cook performance — September 24, 2026

## Ownership and compatibility

Stocked iOS presentation and disposable computation caches own this batch. Recipe IDs, raw titles,
publisher metadata, edits, household persistence and matching constraints remain authoritative and
unchanged. The existing unrelated Localizable.xcstrings work is not included in the commit.

## Photo findings

CachedAsyncImage displayed “Repairing photo” whenever no image was loaded and no request was running.
This incorrectly described a completed failure as active work. Its shared consumers include recipe
heroes, cards, previews, discovery rails, Cook Right Now and recipe grids (22 direct call sites plus
the RecipeHeroImage wrapper). Loading now uses a spinner only during work, a truthful unavailable
state afterward, and a manual retry on images with room for controls. Compact thumbnails retain a
simple icon. Accessibility exposes the real state and the retry control.

Valid embedded photos are checked/decoded before waiting on publisher URLs. The shared URL cache
still coalesces network work, and the title resolver checks warm results before contacting its remote
feed. Local decoding has its own bounded queue so network downloads cannot hold up saved photos. Explicit retry clears remembered title-resolution failures. Task-generation guards prevent a cancelled older task from clearing a newer loading state.
Unavailable publisher content cannot be guaranteed recoverable; no unrelated photo is invented by
this change, and originals are retained.

## Recipe titles

One display-only title-case formatter is applied to recipe cards, detail navigation, Cook choices,
planners, saved/discovered recipes, import previews, cooking screens and recipe history. It normalizes
whitespace, keeps internal small words lowercase and preserves common food acronyms such as BBQ and
BLT. It does not rewrite saved titles or change search/deduplication keys.

## Cook performance

The computation pool now shares the entire cold path: reservation refresh, stable input hashing,
disk lookup and classification. Previously concurrent destinations repeated the expensive setup
before joining the shared classifier. Exact revision checks, per-reader cancellation, allergen
exclusions and reservation rules remain intact. Warm snapshots return immediately. Newly computed
results are published before disposable JSON/disk persistence. Match My Mood tries the downloaded
index before waiting on its network source.

## Verification

Native recipe image policy checks and title-case/idempotence fixtures passed. Native computation-pool
checks passed for shared work, isolated cancellation, pre-cancellation, invalidation/replacement and
last-reader cancellation. These checks are not device latency measurements.

Release Xcode 27.0 (27A266a) generic iOS Debug build 329 passed, including strict deep code-signature verification. The app was installed and launched successfully on the paired iPhone 17 Pro Max after unlocking it to enable development services. Visual review through iPhone Mirroring remains pending; source checks and successful installation do not establish device photo recovery or measured latency improvements.
