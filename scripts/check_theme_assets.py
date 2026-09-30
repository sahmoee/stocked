#!/usr/bin/env python3
"""Execute native checks against the actual theme, artwork router and backup value type."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
tokens = (ROOT / "Stocked/DesignTokens.swift").read_text()
artwork = (ROOT / "Stocked/CachedLocalDataImage.swift").read_text()
backup = (ROOT / "Stocked/KitchenTransferManager.swift").read_text()
theme = tokens[tokens.index("nonisolated enum StockedLightTheme:"):tokens.index("\nnonisolated struct StockedLightThemeTrait")]
router = artwork[artwork.index("nonisolated enum KitchenArtworkCatalog"):artwork.index("\n/// One aspect-preserving")]
preferences = backup[backup.index("nonisolated struct KitchenPreferences:"):backup.index("// MARK: - Complete feature snapshot")]
CHECKS = 'let assets = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Stocked/Assets .xcassets")\nvar checks = 0\nfor theme in StockedLightTheme.allCases {\n    for dark in [false, true] {\n        for name in ["pastel_kitchen_hero", "pastel_ready_meal", "pastel_fresh_produce", "cook_now_hero", "recipes_ready"] {\n            let resolved = KitchenArtworkCatalog.approvedAsset(for: name, dark: dark, lightTheme: theme)\n            let prefix = theme == .tan ? "tan_" : "pastel_"\n            precondition(resolved.hasPrefix(prefix))\n            precondition(resolved.hasSuffix("_dark") == dark)\n            precondition(FileManager.default.fileExists(atPath: assets.appendingPathComponent(resolved + ".imageset/" + resolved + ".png").path))\n            checks += 1\n        }\n        precondition(KitchenArtworkCatalog.approvedAsset(for: "personal-photo", dark: dark, lightTheme: theme) == "personal-photo")\n        checks += 1\n    }\n}\nprecondition(StockedLightTheme(rawValue: "unknown") == nil)\nprecondition(StockedLightTheme.allCases.map(\\.rawValue) == ["Pastel", "Tan"])\nprint("Theme asset routing: \\(checks + 2) checks passed")\n\nvar preference = KitchenPreferences()\npreference.lightTheme = "Tan"\nlet encoded = try JSONEncoder().encode(preference)\nlet roundTrip = try JSONDecoder().decode(KitchenPreferences.self, from: encoded)\nprecondition(roundTrip.lightTheme == "Tan")\nvar legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]\nlegacy.removeValue(forKey: "lightTheme")\nlet old = try JSONDecoder().decode(KitchenPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))\nprecondition(old.lightTheme == nil)\nprint("Theme backup compatibility: 2 checks passed")\n'
with tempfile.TemporaryDirectory(prefix="stocked-theme-") as directory:
    source = Path(directory) / "ThemeChecks.swift"
    source.write_text("import Foundation\n" + theme + "\n" + router + "\n" + preferences + "\n" + CHECKS)
    subprocess.run(["xcrun", "swift", str(source), str(ROOT)], check=True)
