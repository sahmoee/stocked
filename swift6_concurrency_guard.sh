#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIRS=(
  "$ROOT/Stocked"
  "$ROOT/StockedWidgets"
  "$ROOT/StockedShareExtension"
  "$ROOT/Nutrition"
)

existing_dirs=()
for dir in "${SOURCE_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    existing_dirs+=("$dir")
  fi
done

fail=0

check_pattern() {
  local description="$1"
  local pattern="$2"
  local matches
  matches=$(grep -RInE --include='*.swift' "$pattern" "${existing_dirs[@]}" 2>/dev/null || true)
  if [ -n "$matches" ]; then
    echo "SWIFT 6 CONCURRENCY GUARD FAILED: $description"
    echo "$matches"
    echo
    fail=1
  fi
}

# AppIntent metadata is immutable protocol metadata. Stored static vars become
# nonisolated shared mutable state under Swift 6.
check_pattern "AppIntent title must not be stored mutable state" 'static[[:space:]]+var[[:space:]]+title:[[:space:]]*LocalizedStringResource[[:space:]]*='
check_pattern "AppIntent description must not be stored mutable state" 'static[[:space:]]+var[[:space:]]+description[[:space:]]*=[[:space:]]*IntentDescription'
check_pattern "AppIntent openAppWhenRun must not be stored mutable state" 'static[[:space:]]+var[[:space:]]+openAppWhenRun:[[:space:]]*Bool[[:space:]]*='

# PreferenceKey only requires a getter. Mutable defaults create unnecessary
# shared state and fail strict concurrency.
check_pattern "PreferenceKey defaultValue must be immutable" 'static[[:space:]]+var[[:space:]]+defaultValue:'

# Directly shared ISO8601DateFormatter instances are mutable and non-Sendable.
# Use the lock-protected StockedISO8601Formatter wrapper instead.
check_pattern "Do not store ISO8601DateFormatter in a static property" 'static[[:space:]]+(let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[^\n]*ISO8601DateFormatter'

# SwiftData macro-generated initializers are nonisolated, so the schema version
# namespace must remain explicitly nonisolated while the app target defaults to MainActor.
if ! grep -qE '^nonisolated[[:space:]]+enum[[:space:]]+StockedSchema' "$ROOT/Stocked/StockedDataStore.swift"; then
  echo "SWIFT 6 CONCURRENCY GUARD FAILED: StockedSchema must remain nonisolated"
  echo
  fail=1
fi

# Flag stored static vars with explicit initializers. The only intentional mutable
# static state in production is promptTask inside @MainActor NotificationPermissionCoordinator,
# which has no explicit initializer and is actor protected.
stored_static_vars=$(grep -RInE --include='*.swift' '^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+|internal[[:space:]]+|package[[:space:]]+)?(nonisolated[[:space:]]+)?static[[:space:]]+var[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[^\{]*=' "${existing_dirs[@]}" 2>/dev/null || true)
if [ -n "$stored_static_vars" ]; then
  echo "SWIFT 6 CONCURRENCY GUARD FAILED: stored static var found"
  echo "$stored_static_vars"
  echo
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "Swift 6 concurrency guard passed."
