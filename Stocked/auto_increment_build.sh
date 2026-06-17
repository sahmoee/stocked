#!/bin/bash
# auto_increment_build.sh — Auto-increments the build number on every Xcode build.
# ─────────────────────────────────────────────────────────────────────────────
# WHAT IT DOES
#   Bumps CURRENT_PROJECT_VERSION (the build number) by 1 for EVERY target in the
#   project file, in lockstep, on each build. This project sets the build number
#   via Build Settings (Info.plist uses $(CURRENT_PROJECT_VERSION), and
#   GENERATE_INFOPLIST_FILE = NO for the app), so the pbxproj is the single source
#   of truth. BuildConfig.swift reads CFBundleVersion at runtime, so the in-app
#   "Build N · v<version>" label and the What's New header update automatically.
#
#   Keeping all targets on the same number also prevents the App Store warning
#   "CFBundleVersion of an app extension must match its containing parent app".
#
# ── ONE-TIME XCODE SETUP ─────────────────────────────────────────────────────
#   1. Select the Stocked target → Build Phases tab.
#   2. Click "+" (top-left of the phases list) → "New Run Script Phase".
#   3. Drag the new phase so it runs BEFORE "Compile Sources".
#   4. Rename it (double-click the title) to: "Auto-increment build".
#   5. Paste this single line into the script box:
#         "${SRCROOT}/Stocked/auto_increment_build.sh"
#   6. UNCHECK "Based on dependency analysis" so it runs every build.
#   7. Make the file executable once from Terminal:
#         chmod +x "<path to>/auto_increment_build.sh"
#
#   NOTE: because this edits the .pbxproj during the build, the change lands in
#   your working copy — commit it like any other build-number bump. (Xcode is
#   fine with the file changing mid-build; the bumped value is used on the NEXT
#   build, which is the normal behavior for project-file version bumps.)
#
# ── MARKETING VERSION ────────────────────────────────────────────────────────
#   The marketing version (MARKETING_VERSION / CFBundleShortVersionString, e.g.
#   "07.1") is NOT touched here — bump that by hand in the target's General tab
#   when you cut a meaningful release.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

PBXPROJ="${SRCROOT}/Stocked.xcodeproj/project.pbxproj"

if [ ! -f "${PBXPROJ}" ]; then
    echo "warning: auto_increment_build — project file not found at ${PBXPROJ}. Skipping."
    exit 0
fi

# Find the highest CURRENT_PROJECT_VERSION currently set (all targets should match,
# but take the max to be safe), then increment by one.
current=$(grep -Eo 'CURRENT_PROJECT_VERSION = [0-9]+;' "${PBXPROJ}" \
          | grep -Eo '[0-9]+' | sort -n | tail -1)

if [ -z "${current:-}" ]; then
    echo "warning: auto_increment_build — no numeric CURRENT_PROJECT_VERSION found. Skipping."
    exit 0
fi

next=$((current + 1))

# Rewrite every target's build number to the new value, in lockstep.
/usr/bin/sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${next};/g" "${PBXPROJ}"

echo "auto_increment_build: CURRENT_PROJECT_VERSION ${current} → ${next} (all targets)"
