# HANDOFF REPORT

## Summary

Fixed the Swift 6 concurrency error in `Stocked/Formatters.swift`:

`Static property 'iso8601' is not concurrency-safe because non-'Sendable' type 'ISO8601DateFormatter' may have shared mutable state.`

## File Changed

### Stocked/Formatters.swift
- Replaced the directly shared `ISO8601DateFormatter` with a cached `StockedISO8601Formatter` wrapper.
- The wrapper conforms to `@unchecked Sendable` only because all access to its private mutable formatter is serialized with `NSLock`.
- Preserves the existing call-site API:
  - `StockedFormatters.iso8601.string(from:)`
  - `StockedFormatters.iso8601.date(from:)`
- Avoids creating a new formatter on every call.
- No date formatting behavior or output format changed.

## Validation

- `Formatters.swift` passed Swift 6.2 type checking with Foundation.
- Existing `StockedFormatters.iso8601` call sites remain source-compatible.
- No project-file registration changes were required.
