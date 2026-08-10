# README-FIRST — Stocked 2

> **Read this file first, before doing anything in this project.** It is the single source of truth for how to work here. Keep it updated: when the build setup, branch, secrets, or workflow change, edit this file in the same change.

Stocked — iOS app (pantry/inventory).

## Environment: Xcode is on the external SSD, projects are not

- **Xcode.app and ALL Xcode data live on the external SSD "Macintosh SSD"** — DerivedData, simulator devices, archives, DeviceSupport, and caches (relocated + symlinked).
- **This project stays on the internal drive** in Key's Documents folder. Never move the project itself onto the SSD.
- The SSD must be **plugged in to build or run** anything. If builds fail with "Couldn't create workspace arena folder" or missing DerivedData, the SSD is disconnected or Xcode's Derived Data location needs resetting to Default (Xcode ▸ Settings ▸ Locations ▸ Derived Data ▸ Default).

## How to make changes

1. **Edit the live files in place** in this project (it lives in Key's Documents folder on the internal drive). This is the preferred path.
2. **Confirm every change with Key BEFORE making it.** State exactly what you will edit and why, get the go-ahead, then edit.
3. Make **surgical** changes — touch only what the task needs. Read the actual error and the real code before changing anything.
4. If you cannot edit the live files directly, produce a **BuildBuddy delta** instead (see below).

## Cleaning build folders (parent + child) — keep structure intact

Do this when builds go stale, after a scheme/target change, or to reclaim space. It removes **generated build output only** and leaves the source tree byte-for-byte the same.

**1. Xcode-level clean (parent build output):**

```bash
cd "Stocked 2"
xcodebuild -project "Stocked.xcodeproj" -scheme "Stocked" clean
```

**2. Remove this project's DerivedData on the SSD (the parent build folder Xcode complained about):**

```bash
rm -rf "/Volumes/Macintosh SSD/XcodeData/DerivedData/Stocked"-*
```

**3. Sweep nested / child build artifacts anywhere in the tree, preserving structure:**

```bash
cd "Stocked 2"
# Remove only known build-output directories, wherever they are nested:
find . -type d \( -name build -o -name .build -o -name DerivedData -o -name "*.xcarchive" \) -prune -exec rm -rf {} +
# Stray Swift Package caches and object files:
find . -type d -name ".swiftpm" -prune -exec rm -rf {} +
find . -type f -name "*.o" -delete
```

**Structure rule (important):** cleaning must never remove source. Every command above targets only generated artifacts (`build`, `.build`, `DerivedData`, `*.xcarchive`, `.swiftpm`, `*.o`). After cleaning, run `git status` — it should show **no deleted tracked files**. If it shows a deleted source file, restore it immediately with `git checkout -- <path>`. Build artifacts should be in `.gitignore` so they never appear in a commit or a BuildBuddy drop.

## If you CANNOT edit live files: build a BuildBuddy delta

BuildBuddy takes one zipped "drop" of only the changed files, overlays it onto the local repo, then commits and pushes. Package drops in the **BuildBuddy v2 layout**:

```
<drop>.zip
└── Stocked 2/                 <- EXACTLY ONE top folder, named like this repo's root folder
    ├── COMMIT_MSG.txt         <- commit message, plain prose, at the top-folder root
    ├── commit.sh              <- executable helper (commits via: git commit -F COMMIT_MSG.txt)
    └── <path>/<to>/<file>     <- repo-root-relative paths, mirroring the repo exactly
```

Rules:

- One top folder only; its name matches this repo's root folder (`Stocked 2`).
- A file's path inside the top folder equals its path inside the repo (mirror the structure exactly).
- Ship **only genuinely changed files** — overlaying a stale shared file silently reverts other work.
- Edit shared files **additively**; if you must regenerate one, make it the complete cumulative version.
- No junk: exclude `__MACOSX`, `.DS_Store`, and dotfiles.
- `COMMIT_MSG.txt` follows the commit-message rules in the GitHub section (SAFE, plain ASCII, no shell metacharacters).
- Always include an executable `commit.sh` at the top-folder root.

Build the zip from the folder that contains the top folder:

```bash
zip -X -r "<drop>.zip" "Stocked 2" -x ".*" -x "__MACOSX*" -x "*/.DS_Store"
```

Before shipping any drop: parse every changed file (zero new errors), balance braces/parens/brackets, confirm both ends of any caller/definition pair you touched exist, and diff against a current export so the drop contains exactly what changed. Deliver completed files only — no partial edits or train-of-thought in the drop.

## Updating GitHub

- **Remote:** `https://github.com/sahmoee/stocked.git`
- **Default branch:** `main`

Standard flow after a confirmed, applied change:

```bash
cd "Stocked 2"
git add -A
git commit -F COMMIT_MSG.txt          # reads the message verbatim; shell never parses it
git push origin main
```

If BuildBuddy applied the change, it already commits & pushes for you when Auto-commit is on and the message is SAFE — you don't need to run the above.

**Commit-message rules (critical):** the message must be plain ASCII prose with NO shell metacharacters — no backticks, `$(...)`, `$NAME`/`${...}`, double-quotes, backslashes, `*`, `?`, or `...`. Describe flags in words ("git commit dash m", "200 to 299"). Structure with simple ALL-CAPS labels and blank lines, not markdown symbols. Put the message in `COMMIT_MSG.txt` at the repo root.

**Also update the changelog/version** where the project keeps them (see Project specifics) so the commit, changelog, and build number stay in sync.

## Best practices / other improvements

- **Pre-flight (before touching anything):** confirm the SSD is mounted; confirm you're on the right branch and pull latest (`git pull`); confirm Derived Data location is Default; read this file and the project's own docs/ first.
- **One change, one purpose:** keep each edit or drop scoped to a single task so diffs stay reviewable and easy to revert.
- **Back up before destructive edits:** rely on git (commit or stash first). BuildBuddy also snapshots overwritten files on apply and keeps an Apply history with one-click Undo.
- **Verify before committing:** build the scheme (or at minimum parse every changed file) with zero new errors; balance braces/parens/brackets; confirm any caller you touched still has its definition and vice-versa.
- **Unique file names across a target:** projects using Xcode synchronized groups auto-compile every file in a folder, so two files with the same base name (even in different subfolders) collide as 'Multiple commands produce ...'. Name files uniquely. (This is exactly what broke Stocked's BarcodeScannerView.)
- **.gitignore hygiene:** build artifacts (DerivedData, build/, .build/, *.xcarchive, .swiftpm, *.o) must be ignored so they never land in a commit or a BuildBuddy drop.
- **Keep secrets out of git:** use the project's Secrets.xcconfig / example-config pattern; never commit real keys.
- **Keep this file current:** whenever the branch, scheme, secrets, build steps, or workflow change, update README-FIRST.md in the same change. It is checked first, so it must never be stale.

## Project specifics

- **Xcode project:** Stocked.xcodeproj
- **Scheme(s):** Stocked (app), StockedShareExtension, StockedWidgetsExtension
- **Bundle identifier(s):** com.sowens.Stocked (+ .StockedShareExtension, .StockedWidgets)
- **Platform / min OS:** iOS 26.0
- **Repo root folder on disk:** `Stocked 2` (use this exact name for a BuildBuddy drop's top folder)

Notes:

- The on-disk / git repo root folder is 'Stocked 2' even though the app and scheme are 'Stocked'. A BuildBuddy drop's single top folder must be named 'Stocked 2' to match the repo root.
- Secrets: copy Secrets.example.xcconfig to Secrets.xcconfig (already present) — never commit real secrets.
- Uses Xcode synchronized file groups (objectVersion 77): every file in a synced folder is auto-compiled. Two source files with the SAME base name anywhere in the target collide ('Multiple commands produce ...'). Keep file names unique across the whole target.
- StoreKit config: Stocked.storekit. Cross-project notes in CROSS-PROJECT-SYNC.md.
