// QAMockupHandoff.swift
// ─────────────────────────────────────────────────────────────────────────────
// The mockup round trip: bug → ChatGPT → picture → Claude → delta.
//
// THE PROBLEM THIS SOLVES
// "It looks wrong" is the hardest class of bug to hand off, because the fix is
// not described by the failure — it is described by the thing that should have
// happened instead, and nobody has a picture of that. So the loop in practice
// is: tester files a ticket, someone opens an image tool, retypes half the
// context from memory, gets a mockup that is the right idea in the wrong app,
// and then retypes the context a third time to whoever writes the code.
//
// Three retypings, and every one of them loses something. This file removes all
// three. The ticket already knows the screen, the build, the device, the steps
// that led there and what was on fire at the time. So the prompt for the image
// tool is *generated* from the ticket, and the brief that comes back to the
// implementer is generated from the same place plus whatever the mockup added.
//
// TWO BLOCKS, NOT ONE
//   1. `chatGPTPrompt` — everything an image model needs to draw a screen that
//      looks like it belongs in Stocked and not like a generic iOS mockup. The
//      palette and type scale below are lifted from DesignTokens/DesignSystem
//      verbatim, because an image model given "warm, cosy, food app" produces
//      something orange, and Stocked is tan and gold.
//   2. `claudeHandback` — the brief for whoever writes the code afterwards:
//      what was wrong, what the mockup shows, which files are likely involved,
//      and the house rules the delta has to respect. This is the block that
//      closes the loop, and it is the one people forget to write.
//
// WHY IT IS PLAIN TEXT AND NOT A UI
// Both blocks are written into the QA folder as `.md` alongside the screenshot
// and the mockup, *and* offered as copy buttons in the ticket detail. Text in a
// folder survives the app being deleted, works when the tester is not the
// implementer, and can be dragged into any tool. A bespoke UI for this would be
// prettier and would help nobody.
//
// NO SECRETS, EVER
// These strings are pasted into third-party tools by hand. Nothing here reads
// `BuildConfig.stockedWorkerKey`, the worker URL, the cPanel token, or any
// other credential, and nothing here should ever start to.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

nonisolated enum QAMockupHandoff {

    // MARK: - Filenames inside the mirrored folder

    static let promptFileName   = "chatgpt-mockup-prompt.md"
    static let handbackFileName = "claude-handback.md"
    static let reportFileName   = "report.md"
    static let shotFileName     = "screenshot.jpg"
    static let mockupFileName   = "mockup.jpg"

    // MARK: - House style, stated once

    /// The visual brief. Pulled from `DesignTokens.swift` and `DesignSystem.swift`
    /// as literal hex and point sizes rather than adjectives, because "warm and
    /// rustic" gets you a stock photo and "#C7AB81 background, #A27219 accent,
    /// 22pt bold serif titles" gets you Stocked.
    private static let designBrief = """
    Stocked visual language — follow it exactly, do not invent a palette:
    • Light background #C7AB81 (warm tan). Dark background #161410 (near-black).
    • Cards/surfaces: off-white #F5F2EB on light; #2D2C2A charcoal on dark.
    • Primary accent gold #A27219 on light, #DEAD4A on dark. Success #2E9E59,
      warning #D98E2B, error #C0392B, info blue #3B82C4. Ink #1A1712.
    • Titles and headings are a SERIF face, bold — 28pt display, 22pt title,
      18pt headline. Body and labels are the default sans — 15pt body, 12pt
      caption, 11pt semibold label. That serif/sans split is the app's signature;
      an all-sans mockup reads as the wrong app.
    • Corner radius is generous and consistent; cards sit on the tan with a soft
      shadow, not a hard border. Generous vertical rhythm, no dense tables.
    • iOS 26 conventions: large navigation title, a bottom tab bar, SF Symbols
      for iconography, right-aligned chevrons on rows, native sheet grabbers.
    • Portrait iPhone, no device bezel, no drop shadow around the canvas, no
      annotation callouts, no watermark, no lorem ipsum — use plausible real
      food and recipe names in British English.
    """

    // MARK: - Block 1: the prompt for the image tool

    /// The prompt a tester copies into ChatGPT (or any image model) to get a
    /// picture of what the screen *should* have looked like.
    ///
    /// `hasMockup` flips the framing: with no mockup attached this asks for one
    /// to be created from the description; with a mockup already attached it
    /// asks for that image to be refined and made consistent with the house
    /// style, which is the far more common second pass.
    static func chatGPTPrompt(for t: QATicket, hasMockup: Bool) -> String {
        var out: [String] = []

        out.append("# Mockup request — \(t.number)")
        out.append("")
        out.append(hasMockup
            ? "I have attached a rough mockup. Redraw it as a polished, production-quality iOS screen for an app called **Stocked**, keeping the layout intent of my rough but replacing the styling with the house style below. Return a single portrait iPhone screenshot image."
            : "Draw a polished, production-quality iOS screen for an app called **Stocked**, showing how the screen described below *should* look once this bug is fixed. Return a single portrait iPhone screenshot image.")
        out.append("")

        out.append("## What Stocked is")
        out.append("A kitchen inventory and meal-planning app. People log what food they have, and it tells them what they can cook, what is running out, and what to buy. The tone is calm and domestic — a well-kept larder, not a productivity dashboard.")
        out.append("")

        out.append("## The screen")
        out.append("`\(t.context.screen)`")
        out.append("")

        out.append("## What is wrong with it today")
        out.append("**\(t.title)**")
        if !t.body.isEmpty {
            out.append("")
            out.append(reportedBodyOnly(t.body))
        }
        out.append("")

        if !t.context.breadcrumbs.isEmpty {
            out.append("## How the tester got there")
            out.append(t.context.breadcrumbs.suffix(12).map { "- \($0)" }.joined(separator: "\n"))
            out.append("")
        }

        if !t.context.openViolations.isEmpty || !t.context.stalledProcesses.isEmpty {
            out.append("## State at the time (may explain what is missing from the screen)")
            for v in t.context.openViolations.prefix(6) { out.append("- invariant violated: \(v)") }
            for s in t.context.stalledProcesses.prefix(6) { out.append("- stalled: \(s)") }
            out.append("")
        }

        out.append("## House style")
        out.append(designBrief)
        out.append("")

        out.append("## Also tell me, in text under the image")
        out.append("""
        1. Every element you drew, top to bottom, with its role (nav title, card,
           row, empty state, primary button…).
        2. Any element you had to invent because the description did not say —
           call these out explicitly so they can be accepted or rejected.
        3. What specifically differs from what is described as broken above.
        """)
        out.append("")
        out.append("_Generated by Stocked QA · \(t.number) · build \(t.context.build) (\(t.context.appVersion)) · \(t.context.device), \(t.context.os)_")

        return out.joined(separator: "\n")
    }

    // MARK: - Block 2: the brief that closes the loop

    /// The block to hand to whoever writes the fix, after the mockup exists.
    ///
    /// Deliberately opinionated about what it asks for: the constraints section
    /// is the one that stops a "make it look like the mockup" request from
    /// arriving as a rewrite of three view files.
    static func claudeHandback(for t: QATicket) -> String {
        var out: [String] = []

        out.append("# Build request from QA ticket \(t.number)")
        out.append("")
        out.append("A mockup of the intended design \(t.hasMockup ? "is attached (`\(mockupFileName)`)" : "has been produced separately"). Implement it in the Stocked iOS app.")
        out.append("")

        out.append("## The ticket")
        out.append("| | |")
        out.append("|---|---|")
        out.append("| Number | \(t.number) |")
        out.append("| Title | \(t.title) |")
        out.append("| Severity | \(t.severity.title) |")
        out.append("| Status | \(t.status.title) |")
        out.append("| Screen | `\(t.context.screen)` |")
        out.append("| Raised | \(t.createdAt.formatted()) · \(t.originPhrase) |")
        out.append("| Build | \(t.context.appVersion) (\(t.context.build)) |")
        out.append("| Device | \(t.context.device) · \(t.context.os) |")
        if t.wasEdited {
            out.append("| Edited | \(t.editedAt?.formatted() ?? "—") · \(t.editCount ?? 1)× |")
        }
        out.append("")

        if !t.body.isEmpty {
            out.append("## What the tester reported")
            out.append(t.body)
            out.append("")
        }

        out.append("## Attached evidence")
        out.append("- `\(reportFileName)` — the full ticket including environment and breadcrumbs")
        out.append(t.screenshotFile != nil
            ? "- `\(shotFileName)` — what the screen actually looked like\(t.context.touchTrail == nil ? "" : ", with the tester's last taps ringed on it")"
            : "- no screenshot was captured")
        out.append(t.hasMockup
            ? "- `\(mockupFileName)` — what it should look like"
            : "- no mockup attached yet")
        out.append("- `\(promptFileName)` — the prompt the mockup was generated from")
        out.append("")

        if !t.context.breadcrumbs.isEmpty {
            out.append("## Reproduction path")
            out.append(t.context.breadcrumbs.suffix(20).enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n"))
            out.append("")
        }

        let signals = t.context.openViolations + t.context.recentFailures + t.context.stalledProcesses
        if !signals.isEmpty {
            out.append("## Runtime signals at the time")
            out.append(signals.prefix(12).map { "- \($0)" }.joined(separator: "\n"))
            out.append("")
        }

        out.append("## Environment")
        out.append(t.context.summaryLines.map { "- \($0)" }.joined(separator: "\n"))
        out.append("")

        out.append("## What to produce")
        out.append("""
        A delta containing only the files that changed, ready to drop into the
        Xcode synchronised `Stocked/` folder — plus a one-paragraph note saying
        what changed and why, and what to look at to confirm it.
        """)
        out.append("")

        out.append("## Constraints — these are not negotiable")
        out.append("""
        - Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, deployment target
          iOS 26. Types are implicitly `@MainActor` unless marked `nonisolated`.
        - Surgical, single-file changes in preference to refactors. Match the
          surrounding style; do not reformat untouched code.
        - Use the existing design tokens (`Color.stockedGold`, `.stockedBg`,
          `Font.stockedTitle`, …). Do not introduce new literal colours or fonts.
        - Do not edit `project.pbxproj`. New `.swift` files placed in `Stocked/`
          are picked up automatically by the synchronised folder.
        - No third-party AI or vendor API keys in the app under any circumstances
          — anything of that kind goes through the Cloudflare Worker.
        - Bump `BuildConfig.swift` and add an `AppChangelog.swift` entry.
        - Any field added to a persisted `Codable` type must be `Optional`:
          synthesised decoding throws on a missing key instead of falling back to
          the property's default, which silently wipes saved data on upgrade.
        - Verify SF Symbol names actually exist. An unknown symbol does not fail
          the build, it renders as nothing.
        """)
        out.append("")
        out.append("_Generated by Stocked QA on \(Date().formatted()) · \(t.number)_")

        return out.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Strip the appended edit history from a body before handing it to an image
    /// model. The history is valuable to a human reading the ticket and is pure
    /// noise to something being asked to draw a picture.
    private static func reportedBodyOnly(_ body: String) -> String {
        guard let marker = body.range(of: "\n── edited ") else { return body }
        return String(body[body.startIndex..<marker.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
