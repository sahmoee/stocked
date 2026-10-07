#!/usr/bin/env python3
"""Check the actual DesignTokens.swift text colors for both light themes without launching Stocked.

Run: python3 scripts/test-theme-contrast.py

Uses only Python's standard library and reads the source file. It does not build,
launch an app, access app data, or contact a service. This checks semantic color
defaults and the existing widget alpha composite, not rendered Liquid Glass,
page-local opacity overrides, VoiceOver order, or on-device visual appearance.
"""

from pathlib import Path
import math
import re
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "Stocked" / "DesignTokens.swift"
NUMBER = r"(?:\d+(?:\.\d*)?|\.\d+)"
RGB_PATTERN = (
    r"Color\(\s*red:\s*(" + NUMBER + r"),\s*green:\s*(" + NUMBER
    + r"),\s*blue:\s*(" + NUMBER + r")\s*\)"
)


def luminance(rgb):
    """WCAG 2.2 relative luminance for sRGB components in the interval [0, 1]."""
    if len(rgb) != 3 or any(not math.isfinite(v) or not 0 <= v <= 1 for v in rgb):
        raise ValueError("Expected three finite sRGB components between zero and one")
    linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in rgb]
    return sum(weight * value for weight, value in zip((0.2126, 0.7152, 0.0722), linear))


def contrast(foreground, background):
    light, dark = sorted((luminance(foreground), luminance(background)), reverse=True)
    return (light + 0.05) / (dark + 0.05)


def composite(foreground, alpha, background):
    if not 0 <= alpha <= 1:
        raise ValueError("Opacity must be between zero and one")
    return tuple(front * alpha + back * (1 - alpha) for front, back in zip(foreground, background))


def rgb(match):
    if match is None:
        raise ValueError("The expected literal RGB source expression was not found")
    return tuple(float(value) for value in match.groups())


UICOLOR_PATTERN = (
    r"UIColor\(\s*red:\s*(" + NUMBER + r"),\s*green:\s*(" + NUMBER + r"),\s*blue:\s*("
    + NUMBER + r"),\s*alpha:\s*(" + NUMBER + r")\s*\)"
)
# Light colors resolve per selected light theme through `stockedPalette(pastel:tan:)`.
PALETTE_PATTERN = (
    r"stockedPalette\(\s*pastel:\s*" + UICOLOR_PATTERN + r",\s*tan:\s*" + UICOLOR_PATTERN + r"\s*\)"
)
THEMES = ("pastel", "tan")


def palette_color(match, theme):
    """Return (rgb, alpha) for one theme branch of a stockedPalette match (its last 8 groups)."""
    if match is None:
        raise ValueError("The expected stockedPalette source expression was not found")
    values = [float(value) for value in match.groups()[-8:]]
    branch = values[:4] if theme == "pastel" else values[4:]
    return tuple(branch[:3]), branch[3]


def opaque(color):
    rgb_value, alpha = color
    if alpha != 1:
        raise ValueError("Expected an opaque color; add explicit composite coverage")
    return rgb_value


def function_body(source, name):
    start = re.search(r"static\s+func\s+" + re.escape(name) + r"\s*\(", source)
    if start is None:
        raise ValueError("Missing DesignTokens function: " + name)
    opening = source.find("{", start.end())
    depth = 1
    for index in range(opening + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[opening + 1:index]
    raise ValueError("Unterminated DesignTokens function: " + name)


def semantic_token(source, function, dark, visited=()):
    """Follow the production semantic helper, including its one-line forwarding calls."""
    if function in visited:
        raise ValueError("Recursive semantic color helper: " + function)
    body = function_body(source, function).strip()
    body = re.sub(r"^return\s+", "", body)
    if branch := re.fullmatch(r"dark\s*\?\s*(\w+)\s*:\s*(\w+)", body):
        return branch.group(1 if dark else 2)
    if forwarding := re.fullmatch(r"(\w+)\(dark\)", body):
        return semantic_token(source, forwarding.group(1), dark, visited + (function,))
    raise ValueError("Update contrast coverage for the changed semantic helper: " + function)


def source_palette(theme):
    """Resolve the production tokens for one light theme. Dark tokens are theme-independent."""
    source = SOURCE.read_text(encoding="utf-8")
    tokens = {
        name: tuple(float(component) for component in values)
        for name, *values in re.findall(r"static\s+let\s+(\w+)\s*=\s*" + RGB_PATTERN, source)
    }
    for match in re.finditer(r"static\s+let\s+(\w+)\s*=\s*" + PALETTE_PATTERN, source):
        tokens[match.group(1)] = opaque(palette_color(match, theme))
    required = {
        "stockedBg", "stockedDarkBg", "stockedCharcoal", "stockedBlack", "stockedWhite",
        "darkSurface", "darkLabel", "secondaryLight", "secondaryDark", "textAccentLight",
        "stockedGold", "stockedGoldDark", "lightSurface", "darkElevatedSurface",
    }
    if missing := required - tokens.keys():
        raise ValueError("Missing RGB text/surface tokens: " + ", ".join(sorted(missing)))
    # Read the widget accessibility variants and translucent fill from production code.
    # Fail visibly if this implementation changes so new surfaces cannot escape the check.
    body = function_body(source, "widgetSurface")
    dark_increased = rgb(re.search(r"if dark\s*\{\s*return increasedContrast\s*\?\s*" + RGB_PATTERN, body))
    light_increased = opaque(palette_color(
        re.search(r"if increasedContrast\s*\{\s*return\s*" + PALETTE_PATTERN, body), theme))
    reduced = re.search(r"return reduceTransparency\s*\?\s*(\w+)\s*:\s*" + PALETTE_PATTERN, body)
    if reduced is None:
        raise ValueError("Missing the expected widget surface expression")
    light_reduced = tokens[reduced.group(1)]
    translucent, alpha = palette_color(reduced, theme)
    light_surfaces = {
        "page": tokens["stockedBg"],
        "elevated surface": tokens["lightSurface"],
        "widget / reduced transparency": light_reduced,
        "widget / increased contrast": light_increased,
        "widget / page composite": composite(translucent, alpha, tokens["stockedBg"]),
        "widget / surface composite": composite(translucent, alpha, tokens["lightSurface"]),
    }
    dark_surfaces = {
        "page": tokens["stockedDarkBg"],
        "base surface": tokens["darkSurface"],
        "elevated surface / widget": tokens["darkElevatedSurface"],
        "widget / increased contrast": dark_increased,
    }
    return tokens, light_surfaces, dark_surfaces


class ContrastChecks(unittest.TestCase):
    def test_pastel_feature_card_text(self):
        """Check the actual feature fills, including their separate dark variants."""
        source = SOURCE.with_name("PastelDesign.swift").read_text(encoding="utf-8")
        for theme in THEMES:
            tokens, _, _ = source_palette(theme)
            for fill in ("oat", "garden", "peach"):
                branches = list(re.finditer(PALETTE_PATTERN, function_body(source, fill)))
                self.assertEqual(len(branches), 2, f"Update contrast coverage for {fill}")
                for dark, branch in zip((True, False), branches):
                    background = opaque(palette_color(branch, theme))
                    for role in (("darkLabel", "secondaryDark", "stockedGoldDark") if dark
                                 else ("stockedBlack", "secondaryLight", "textAccentLight")):
                        with self.subTest(theme=theme, fill=fill, dark=dark, role=role):
                            self.assertGreaterEqual(contrast(tokens[role], background), 4.5)

    def test_adaptive_legacy_ink_on_dark_cards(self):
        source = SOURCE.read_text(encoding="utf-8")
        for theme in THEMES:
            tokens, _, dark_surfaces = source_palette(theme)
            for name in ("stockedAccentInk", "stockedSuccessInk"):
                body = source.split("static let " + name + " =", 1)[1].split("})", 1)[0]
                match = re.search(r"UIColor\(red: ([\d.]+), green: ([\d.]+), blue: ([\d.]+), alpha: 1\)", body)
                ink = rgb(match)
                for surface, background in dark_surfaces.items():
                    with self.subTest(theme=theme, ink=name, surface=surface):
                        self.assertGreaterEqual(contrast(ink, background), 4.5)
            with self.subTest(theme=theme, fill="stockedGold"):
                self.assertGreaterEqual(contrast(tokens["stockedWhite"], tokens["stockedGold"]), 4.5)

    def test_reference_values_and_threshold(self):
        self.assertAlmostEqual(contrast((0, 0, 0), (1, 1, 1)), 21)
        self.assertEqual(contrast((0.5, 0.5, 0.5), (0.5, 0.5, 0.5)), 1)
        self.assertGreaterEqual(contrast((118 / 255,) * 3, (1, 1, 1)), 4.5)
        self.assertLess(contrast((119 / 255,) * 3, (1, 1, 1)), 4.5)
        self.assertAlmostEqual(luminance((0.04, 0.04, 0.04)), 0.04 / 12.92)
        self.assertAlmostEqual(luminance((0.05, 0.05, 0.05)), ((0.05 + 0.055) / 1.055) ** 2.4)
        self.assertEqual(composite((1, 0, 0), 0.5, (0, 0, 1)), (0.5, 0, 0.5))

    def test_palette_parser_resolves_each_theme(self):
        sample = ("stockedPalette(pastel: UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1), "
                  "tan: UIColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 0.9))")
        match = re.search(PALETTE_PATTERN, sample)
        self.assertEqual(palette_color(match, "pastel"), ((0.1, 0.2, 0.3), 1.0))
        self.assertEqual(palette_color(match, "tan"), ((0.4, 0.5, 0.6), 0.9))
        with self.assertRaises(ValueError):
            opaque(palette_color(match, "tan"))

    def test_source_text_roles(self):
        source = SOURCE.read_text(encoding="utf-8")
        functions = ("appText", "appSecondary", "appAccent", "widgetPrimaryText", "widgetSecondaryText", "widgetFocus")
        for theme in THEMES:
            tokens, light_surfaces, dark_surfaces = source_palette(theme)
            for appearance, dark, backgrounds in (("light", False, light_surfaces), ("dark", True, dark_surfaces)):
                for function in functions:
                    role = semantic_token(source, function, dark)
                    ratios = {name: contrast(tokens[role], color) for name, color in backgrounds.items()}
                    minimum_name = min(ratios, key=ratios.get)
                    print(f"{theme} {appearance} {function} ({role}): minimum {ratios[minimum_name]:.3f}:1 on {minimum_name}")
                    for name, ratio in ratios.items():
                        with self.subTest(theme=theme, appearance=appearance, function=function, role=role, surface=name):
                            # Compare full precision. A ratio below 4.5 cannot be rounded into a pass.
                            self.assertGreaterEqual(ratio, 4.5, f"{role} on {name}: {ratio:.6f}:1 < 4.5:1")

    def test_selected_tab_content(self):
        source = SOURCE.read_text(encoding="utf-8")
        background = re.search(r"static\s+let\s+selectedTabBackground\s*=\s*(\w+)", source)
        self.assertIsNotNone(background, "Update contrast coverage for the changed selected-tab fill")
        for theme in THEMES:
            tokens, _, _ = source_palette(theme)
            for dark in (False, True):
                role = semantic_token(source, "selectedTabForeground", dark)
                with self.subTest(theme=theme, role=role):
                    self.assertGreaterEqual(contrast(tokens[role], tokens[background.group(1)]), 4.5)

    def test_text_roles_retain_hierarchy_and_decoration(self):
        for theme in THEMES:
            tokens, _, _ = source_palette(theme)
            with self.subTest(theme=theme):
                self.assertGreater(luminance(tokens["secondaryLight"]), luminance(tokens["stockedBlack"]))
                self.assertLess(luminance(tokens["secondaryDark"]), luminance(tokens["darkLabel"]))
                self.assertNotEqual(tokens["textAccentLight"], tokens["secondaryLight"])
                self.assertNotEqual(tokens["textAccentLight"], tokens["stockedGold"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
