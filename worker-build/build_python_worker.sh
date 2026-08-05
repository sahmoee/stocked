#!/usr/bin/env bash
# build_python_worker.sh — build the optional recipe-scrapers helper for Stocked for Mac.
#
# Produces the `StockedRecipeWorker` executable and drops it into the app target's
# Resources, where AppPaths.bundledResource("StockedRecipeWorker") finds it at runtime.
# This is the ONLY step that must run on a Mac: PyInstaller emits a native Mach-O binary,
# so a Linux-built copy will not run on macOS. Everything else in the Harvester is pure
# Swift and builds in Xcode with no setup.
#
#   cd "Stocked Mac/worker-build"
#   ./build_python_worker.sh
#
# Requirements on the Mac: python3 (3.10–3.12) and Xcode command-line tools. The script
# creates its own virtualenv; it installs nothing globally.
#
# ── Read this before shipping ────────────────────────────────────────────────────────
# The App Store build of Stocked for Mac is sandboxed and hardened. A sandboxed app cannot
# reliably spawn this binary — a PyInstaller executable unpacks and re-execs from a temp
# directory, which App Sandbox + Library Validation block. So on the shipping build the
# Python worker is effectively unavailable, and the Harvester falls back to the regular
# Stocked Worker (see HarvestWorkerParser.swift) for model-backed parsing.
#
# This binary is therefore for LOCAL / developer builds where you run the Harvester with
# the sandbox relaxed, or for a Developer-ID (non-App-Store) distribution. For the App
# Store, leave it out and rely on the native parser + the Worker fallback.
# ─────────────────────────────────────────────────────────────────────────────────────

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$HERE/.." && pwd)"

# worker.py lives here (build input) and is also bundled in the app's Resources as
# reference; this copy is the source of truth for the build.
WORKER_PY="$HERE/worker.py"
RESOURCES="$PROJECT_ROOT/StockedMac/Harvest/Resources"
OUTPUT="$RESOURCES/StockedRecipeWorker"

VENV="$HERE/.venv"
BUILD_DIR="$HERE/.pyinstaller"

echo "==> Stocked recipe worker build"
echo "    worker.py : $WORKER_PY"
echo "    output    : $OUTPUT"

if [[ ! -f "$WORKER_PY" ]]; then
  echo "!! worker.py not found at $WORKER_PY" >&2
  exit 1
fi

PY="${PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "!! python3 not found. Install it (brew install python) and retry." >&2
  exit 1
fi

echo "==> Creating virtualenv"
"$PY" -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"

echo "==> Installing recipe-scrapers + PyInstaller"
python -m pip install --quiet --upgrade pip
python -m pip install --quiet -r "$HERE/requirements.txt"
python -m pip install --quiet "pyinstaller>=6.3,<7"

echo "==> Running PyInstaller (onefile)"
# --collect-all recipe_scrapers pulls in the per-site scraper modules it loads by name,
# which a bare analysis would miss and which would then fail only at runtime on some sites.
pyinstaller \
  --clean --noconfirm \
  --name StockedRecipeWorker \
  --onefile \
  --console \
  --collect-all recipe_scrapers \
  --distpath "$BUILD_DIR/dist" \
  --workpath "$BUILD_DIR/work" \
  --specpath "$BUILD_DIR" \
  "$WORKER_PY"

BUILT="$BUILD_DIR/dist/StockedRecipeWorker"
if [[ ! -x "$BUILT" ]]; then
  echo "!! Build did not produce an executable at $BUILT" >&2
  exit 1
fi

echo "==> Installing into app Resources"
mkdir -p "$RESOURCES"
cp "$BUILT" "$OUTPUT"
chmod +x "$OUTPUT"

# Ad-hoc sign so a hardened-runtime local build does not kill it on first exec. For a
# Developer-ID distribution, re-sign with your identity and notarize the containing app.
echo "==> Ad-hoc signing"
codesign --force --sign - "$OUTPUT" || {
  echo "   (codesign unavailable — the binary is unsigned; a hardened build may reject it)"
}

echo "==> Smoke test"
echo '{"mode":"classify","url":"https://example.com/recipe","html":"<html><script type=\"application/ld+json\">{\"@type\":\"Recipe\",\"name\":\"Test\"}</script></html>"}' \
  | "$OUTPUT" || {
    echo "!! Smoke test failed — the binary ran but returned an error above." >&2
    exit 1
  }
echo
echo "==> Done. StockedRecipeWorker is in place at:"
echo "    $OUTPUT"
echo "   Because StockedMac/ is an Xcode synchronized folder, it is added to the app"
echo "   target automatically. Build in Xcode; no project-file change is needed."
echo
echo "   Reminder: the sandboxed App Store build cannot spawn it — the Worker fallback"
echo "   covers that case. See build_python_worker.sh header and CHANGES.md."

deactivate || true
