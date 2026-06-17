// SubstitutionDatabase.swift
// DEPRECATED — all logic is in StockedDatabase.swift.
// This file is intentionally minimal. Replace calls:
//   SubstitutionDatabase.shared.substitutions(for:) → StockedDatabase.shared.substitutions(for:)
//   SubstitutionDatabase.shared.hasSubstitution(for:) → StockedDatabase.shared.hasSubstitution(for:)
// This shim is kept only for call-site compatibility during migration.
import Foundation

@available(*, deprecated, renamed: "StockedDatabase")
typealias SubstitutionDatabase = StockedDatabase
