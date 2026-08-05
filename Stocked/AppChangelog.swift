// AppChangelog.swift — Version history and feature changelog for Stocked.
// HOW TO UPDATE: After each confirmed working build, add a new ChangelogVersion
// entry at the TOP of the `versions` array. Keep descriptions user-friendly —
// no technical jargon. Think: "what would a home cook want to know?"
import SwiftUI

// MARK: - Data model

struct ChangelogEntry: Identifiable {
    let id = UUID()
    let icon: String      // SF Symbol name
    let color: Color      // icon background colour
    let title: String     // short feature name
    let detail: String    // plain-English explanation
}

struct ChangelogVersion: Identifiable {
    let id = UUID()
    let version: String       // e.g. "1.1"
    let buildDate: String     // human-readable, e.g. "June 2025"
    let headline: String      // one-liner shown in collapsed row
    let isLatest: Bool
    let entries: [ChangelogEntry]
}

// MARK: - Changelog data
// ⚠️  DEVELOPER NOTE: Add new versions at the TOP. Oldest at the bottom.
// Only add a version here once the user has confirmed it compiled and works.

struct StockedChangelog {

    // ── PENDING (not yet confirmed working — do NOT add here yet) ────────────
    // Next build candidates:
    //   • Onboarding quiz responsive layout (all iPhone screen sizes)
    //   • Settings collapsible dropdown
    //   • Expanded font picker with 14 named fonts + custom font import
    //   • iCloud data sync for Sign in with Apple users
    // ────────────────────────────────────────────────────────────────────────

    static let versions: [ChangelogVersion] = [
                // -- 4.29 (build 89) -- Two retired recipe sources cleared out --
                ChangelogVersion(
                    version: "4.29",
                    buildDate: "Build 89 \u{00B7} August 1, 2026",
                    headline: "What's new in Stocked",
                    isLatest: true,
                    entries: [
                        ChangelogEntry(icon: "trash.slash.circle", color: Color.stockedError,
                                       title: "Two old recipe sources are gone",
                                       detail: "Early versions of Stocked filled the library out with a bulk food dataset and a small curated feed. Neither was ever much use \u{2014} the dataset recipes were terse and often had no picture, and the curated feed was a handful of entries that never grew. Both are now removed from your library and blocked from being added back, on your phone and on your Mac."),
                        ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                                       title: "It happens by itself",
                                       detail: "Nothing is asked of you. The next time each app opens it clears them out quietly in the background, and it keeps checking on every launch rather than just once \u{2014} so if a recipe arrives from another device still on an older version, it goes too instead of quietly refilling your library."),
                        ChangelogEntry(icon: "hand.raised", color: Color.stockedInfo,
                                       title: "Only those two, and only by source",
                                       detail: "Recipes you wrote, recipes you saved from anywhere else, and anything you harvested from a website are all untouched. A recipe is only ever judged by where it came from, never by its title or what is in it \u{2014} so something you typed by hand that happens to use one of those words as a tag stays exactly where it is.")
                    ]),

                // -- 4.28 (build 88) -- Clearing out recipes with a spreadsheet --
                ChangelogVersion(
                    version: "4.28",
                    buildDate: "Build 88 \u{00B7} August 1, 2026",
                    headline: "What's new in Stocked",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "tablecells.badge.ellipsis", color: Color.stockedGold,
                                       title: "Your recipes, as a spreadsheet",
                                       detail: "Kitchen Transfer can now write out every recipe you have \u{2014} the ones you wrote, the ones you saved \u{2014} as a plain spreadsheet you can open in Numbers, Excel or anything else. It is a readable list of what is actually in your library, which turns out to be the first time most people find out."),
                        ChangelogEntry(icon: "trash.slash", color: Color.stockedError,
                                       title: "Remove a lot of recipes at once",
                                       detail: "Clearing out recipes one at a time is why nobody does it. Put yes in the remove column beside the ones you are done with, save the file, and hand it back to Stocked. Fifty recipes go in one sitting instead of fifty swipes, and the same file works on the Mac, so a tidy-up can start on a laptop and finish on your phone."),
                        ChangelogEntry(icon: "checklist", color: Color.stockedInfo,
                                       title: "You see the list before anything goes",
                                       detail: "Stocked shows you exactly which recipes it matched. Where there is only one possible answer it arrives ticked. Where a title matches two recipes it arrives unticked, both of them side by side with enough detail to tell them apart, because guessing there is how you delete the wrong dinner. Rows that matched nothing are listed too, so a typo reads as a typo instead of quietly doing nothing. And a copy of everything removed is saved first, so a mistake is recoverable rather than final.")
                    ]),

                // -- 4.27 (build 87) -- Recipes from the Mac, on their own --
                ChangelogVersion(
                    version: "4.27",
                    buildDate: "Build 87 \u{00B7} August 1, 2026",
                    headline: "What's new in Stocked",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "arrow.down.circle", color: Color.stockedGreen,
                                       title: "Recipes found on the Mac arrive here by themselves",
                                       detail: "A recipe the Mac found used to need two separate button presses on the Mac before it could reach your phone, and even then the Mac only ever asked for changes rather than sending its own \u{2014} so it could sit there until somebody synced by hand. Approving a recipe on the Mac now hands it straight to your kitchen, and the Mac sends as well as receives. It shows up here within seconds."),
                        ChangelogEntry(icon: "photo", color: Color.stockedGold,
                                       title: "The photo comes with the recipe",
                                       detail: "Recipe pictures were being accepted on the Mac and then quietly dropped on the way here, so recipes arrived with a blank card. The picture is now resized to fit what sync can carry instead of being thrown away, and addresses written relative to the page they came from are worked out properly rather than stored as something no phone could follow."),
                        ChangelogEntry(icon: "square.and.arrow.down", color: Color.stockedInfo,
                                       title: "Pictures that used to stay grey now load",
                                       detail: "Many recipe sites refuse to hand over their photographs to anything that does not look like a web browser, which is why some cards showed a grey rectangle for a picture that opens perfectly in Safari. Stocked now asks the way a browser asks."),
                        ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGoldDark,
                                       title: "A big kitchen no longer stops syncing",
                                       detail: "Once enough recipes carried photographs, the whole sync could be refused for being too large \u{2014} not just the recipe with the big picture, but your groceries and inventory too. Now the embedded photographs come off first, which still load from the web, so everything else keeps moving. No recipe is ever dropped to make room."),
                    ]
                ),
                // -- 4.21 (build 77) -- Two apps, on purpose --
                ChangelogVersion(
                    version: "4.21",
                    buildDate: "Build 77 \u{00B7} July 28, 2026",
                    headline: "What's new in Stocked",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "macwindow", color: Color.stockedGold,
                                       title: "The Mac version is its own app now",
                                       detail: "Last build put the Mac inside the iPhone app and made the two share one project. It worked, but it meant every Mac decision was also an iPhone decision, and a mistake on one side could stop the other from building at all. Stocked for Mac is now a separate app with its own project and its own place on the Mac App Store. It is written for a Mac from the first line rather than adapted from a phone."),
                        ChangelogEntry(icon: "iphone", color: Color.stockedInfo,
                                       title: "The iPhone app is an iPhone app again",
                                       detail: "Everything the Mac needed has come back out: the extra platform checks, the menu bar, the Mac-only permissions and the settings that only ever applied to a desktop. Nothing you use on iPhone or iPad changed, and nothing about this app has to think about a Mac any more."),
                        ChangelogEntry(icon: "bolt.heart", color: Color.stockedError,
                                       title: "The launch failure cannot come back",
                                       detail: "The crash in the last build came from the app, the widgets and the share sheet trying to share one store across two platforms that name that store differently. There is no longer anything shared between the two apps that can be named wrong, so that whole class of failure is gone rather than patched."),
                        ChangelogEntry(icon: "sidebar.left", color: Color.stockedGoldDark,
                                       title: "A Mac app that behaves like one",
                                       detail: "A sidebar with your kitchen, inventory, grocery list, recipes and the week's plan. Inventory is a proper sortable table you can multi-select, edit in place and act on in bulk. The grocery list keeps the cursor in the add field so eleven items are eleven words and eleven returns. And there is a menu bar item showing how stocked you are and what needs using up without opening the window at all."),
                        ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGreen,
                                       title: "Your kitchen still follows you",
                                       detail: "Open Household on the Mac, type the code from your phone, and everything appears. The Mac joins as another device in the same household and reads and writes the same kitchen, grocery list, recipes and plan. Two separate apps, one kitchen \u{2014} which was the point of separating them in the first place."),
                        ChangelogEntry(icon: "doc.badge.arrow.up", color: Color.stockedInfo,
                                       title: "Export and import, as one file",
                                       detail: "The Mac can write your whole kitchen to a single file anywhere you like, and read one back \u{2014} asking first whether to merge it with what you have or replace it. It is a backup you can keep, mail to yourself, or hand to someone setting up their own."),
                        ChangelogEntry(icon: "lock.shield", color: Color.stockedWarning,
                                       title: "Nothing sensitive in either app",
                                       detail: "The Mac app carries no keys of its own. Anything that needs one goes through the same service the phone uses, which holds it privately. The Mac asks for exactly three things from macOS: a sandbox to live in, permission to reach the network, and permission to open the one file you picked."),
                        ChangelogEntry(icon: "checkmark.seal", color: Color.stockedGreen,
                                       title: "Ready to submit as it is",
                                       detail: "Signing, the sandbox, the hardened runtime, the App Store category and a full set of Mac icons are all in place, so the Mac app can be archived and uploaded without a setup step first. It runs on macOS Sonoma and everything newer.")
                    ]),

                // -- 4.20 (build 76) -- Stocked on the Mac --
                ChangelogVersion(
                    version: "4.20",
                    buildDate: "Build 76 \u{00B7} July 28, 2026",
                    headline: "What's new in Stocked",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "desktopcomputer", color: Color.stockedGold,
                                       title: "Stocked runs on the Mac",
                                       detail: "Same app, same account, same kitchen \u{2014} opened on a Mac rather than reached for on a phone. It is not a phone app in a small window: it is the app you already have, built to run on macOS, with a real menu bar, real windows and the Mac's own keyboard shortcuts. Everything syncs the way it already did, because it is the same app talking to the same account."),
                        ChangelogEntry(icon: "bolt.heart", color: Color.stockedError,
                                       title: "The launch failure, fixed at the cause",
                                       detail: "The app, the widgets and the share sheet all read from one shared store, and that store is named one way on a phone and another way on a Mac. With the phone name in place, macOS refused the store outright and stopped the app dead at launch \u{2014} every single time, before anything appeared. The name is now worked out once, for whichever platform you are on, and every part of the app that reads the store gets it from there."),
                        ChangelogEntry(icon: "heart.text.square", color: Color.stockedInfo,
                                       title: "Apple Health, where Apple Health exists",
                                       detail: "There is no Health app on a Mac and no way to write to it, so the parts of Stocked that log a cooked meal to Health now know that. On a Mac the Health switch and everything behind it is simply not there, rather than sitting in Settings looking available and doing nothing. On iPhone and iPad it works exactly as it always has."),
                        ChangelogEntry(icon: "app.badge", color: Color.stockedGoldDark,
                                       title: "Alternate icons are a phone idea",
                                       detail: "A Mac app's icon comes from the app itself, not from a switch inside it \u{2014} the phone instruction is accepted on a Mac and then quietly ignored. Rather than leave a picker that opens, looks right and changes nothing, the icon picker and the settings rows that open it are hidden on the Mac. Nothing changed on iPhone or iPad."),
                        ChangelogEntry(icon: "sun.max", color: Color.stockedGreen,
                                       title: "The screen stays awake while you cook",
                                       detail: "Telling the screen not to sleep is a phone instruction and a Mac ignores it, which would have meant the display dimming halfway through a recipe with your hands covered in flour. The Mac now holds a proper system assertion for the length of the cook and hands it back the moment you finish or leave, so nothing is held open longer than it should be."),
                        ChangelogEntry(icon: "menubar.rectangle", color: Color.stockedGold,
                                       title: "A real menu bar",
                                       detail: "Settings on Command comma. New item, quick update, scan a receipt and scan a barcode under File, with search beside them. The five tabs on Command 1 through 5. A Kitchen menu holding household, activity, statistics, food databases, recipe sources, your preferred store, notifications, data and storage, transfer kitchen and edit profile \u{2014} all of it reachable without opening the drawer. Help points at the support, privacy and terms pages that actually exist."),
                        ChangelogEntry(icon: "iphone", color: Color.stockedInfo,
                                       title: "Nothing changed on iPhone or iPad",
                                       detail: "The menu bar resolves to nothing at all off the Mac, so the hardware-keyboard shortcuts already built into the iPad \u{201C}Command N, Command F, Command 1 to 4\u{201D} keep working exactly as before, with no chance of two things claiming the same key. Every Mac-specific change in this build is written so that the iPhone and iPad builds are byte for byte what they were."),
                        ChangelogEntry(icon: "lock.shield", color: Color.stockedWarning,
                                       title: "Permissions the Mac actually asks for",
                                       detail: "A Mac app runs in a sandbox and gets nothing it has not asked for \u{2014} and the usual way this goes wrong is that the app launches, looks perfectly fine, and cannot reach the network at all. Stocked ships with exactly what it uses and nothing more: network, camera for scanning, microphone for voice control while cooking, the photo library, and file panels for importing and exporting."),
                        ChangelogEntry(icon: "link", color: Color.stockedGreen,
                                       title: "A link bug that was live on iPhone too",
                                       detail: "The file the website serves to prove Stocked owns its own links still had a placeholder sitting where the team identifier belongs. That quietly broke two things everywhere, not just on the Mac: tapping a Stocked link opened the browser instead of the app, and saved passwords were not shared between the app and the site. The real identifier is in place.")
                    ]),

                // ── 4.19 (build 75) — What the field report proved ──
                ChangelogVersion(
                    version: "4.19",
                    buildDate: "Build 75 \u{00B7} July 28, 2026",
                    headline: "What's new in Stocked",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "book.closed", color: Color.stockedError,
                                       title: "Every recipe Cook Now offers has a recipe in it",
                                       detail: "Some of the recipes Cook Now suggested had no method \u{2014} you would tap one meaning to cook it and find nothing to follow. The Cook tab loads its pool of recipes from the copy saved on your phone, and that one route skipped the check every other part of the app runs: does this recipe actually come with steps, or is it just a pointer back to wherever it came from. Cook Now was ranking recipes the Recipes tab would never have shown you. It now runs the same check, and so does the part that scores them, so there are two places it has to get past instead of none."),
                        ChangelogEntry(icon: "tray.and.arrow.down", color: Color.stockedGoldDark,
                                       title: "And opening one no longer keeps it",
                                       detail: "Opening a recipe from Cook Now saves it into your collection, so that renaming, favouriting and cooking it all work on something real. That was fine until an empty recipe went through it \u{2014} then the empty one was yours, permanently, and no later fix could reach it. Saving now either fills the steps back in from the live recipe of the same name or leaves it unsaved. Nothing without a method gets written into your collection."),
                        ChangelogEntry(icon: "speedometer", color: Color.stockedGold,
                                       title: "Cook Now stopped redoing work it had already done",
                                       detail: "Working out what you can cook is the heaviest thing the app does, so it keeps the answer and reuses it until your kitchen changes. A background check was quietly asking the same question in a slightly different way and knocking the saved answer out every time \u{2014} fifteen full passes over a hundred and thirty-four recipes in seven minutes, three of them inside half a second with nothing changed in between, and every stutter in that session sat on top of one. It now recognises the two as the same question and keeps more than one answer, so the Cook, Home and Grocery screens stop hitching."),
                        ChangelogEntry(icon: "checkmark.seal", color: Color.stockedGreen,
                                       title: "The app watches for both of these coming back",
                                       detail: "Two new checks run alongside the ones already there. One asks whether every recipe Cook Now is offering can actually be cooked from, at the point you would see it, so it does not matter which route let it through. The other watches for the app repeating expensive work against information that has not changed, which never showed up in anything before \u{2014} each pass on its own looked perfectly normal, and only the gap between them gave it away.")
                    ]),

                // ── 4.18 (build 74) — Testing mode, one door ──
                ChangelogVersion(
                    version: "4.18",
                    buildDate: "Build 74 \u{00B7} July 28, 2026",
                    headline: "Testing mode has one door",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "door.left.hand.open", color: Color.stockedGold,
                                       title: "Testing mode has one door now",
                                       detail: "It used to live in two places \u{2014} once under Settings, and again buried inside App Health \u{2014} with different things in each and a passcode on both. App Health is back to being about the app's health. Everything to do with testing is under Settings, Testing, and nowhere else: one screen to learn, one passcode, one report to send."),
                        ChangelogEntry(icon: "magnifyingglass", color: Color.stockedInfo,
                                       title: "One search box for everything",
                                       detail: "Checks, reports, screens, the things the app quietly verifies about itself, everything it recorded you doing, everything it has published \u{2014} six separate lists, and remembering which one held the thing you half-remember was your problem, not the app's. Type the word. It looks in all six and tells you which is which."),
                        ChangelogEntry(icon: "ticket", color: Color.stockedGoldDark,
                                       title: "A failed check becomes a real report",
                                       detail: "Marking something failed in the release checklist used to leave a sentence sitting in a list that went nowhere and had no number. It now offers to turn that into a proper numbered report \u{2014} already filled in with what the check was asking for \u{2014} which syncs everywhere the others do. The check remembers its report number and the report remembers the check."),
                        ChangelogEntry(icon: "repeat", color: Color.stockedError,
                                       title: "Things that keep coming back",
                                       detail: "Reporting the same problem twice used to make two reports that nobody could tell were the same problem. A new report that closely matches one already filed now marks the original as seen again and counts it, and there is a screen listing everything that has come back more than once. Anything on that list marked fixed is a fix that did not hold, which is the most useful thing testing can tell you."),
                        ChangelogEntry(icon: "textformat.size", color: Color.stockedGreen,
                                       title: "Reports know what your screen was set to",
                                       detail: "Half of all \u{201C}the layout is broken\u{201D} reports are a screen at the largest text size, or in landscape, or with Reduce Motion on \u{2014} and none of that was ever written down, so nobody reading the report could reproduce it. Every report now carries the text size, light or dark, the rotation, the exact screen it was on, and which accessibility settings were switched on."),
                        ChangelogEntry(icon: "iphone.gen3.radiowaves.left.and.right", color: Color.stockedGold,
                                       title: "Shake the phone to report something",
                                       detail: "Press and hold works everywhere except the places bugs actually happen \u{2014} mid-scroll, mid-drag, or in a text field, where the press is already taken by something else. Two quick shakes now opens the report instead, capturing the screen as it was rather than as it looked after you let go. On by default while testing mode is on, and switchable."),
                        ChangelogEntry(icon: "figure.walk.circle", color: Color.stockedInfo,
                                       title: "A check for the problems you cannot see",
                                       detail: "A button with an icon and no label is a perfectly good button to look at and reads out as \u{201C}Button\u{201D} to anyone using VoiceOver. A tap target under 44 points is fine for whoever built it and a coin toss for someone with a tremor. Neither shows up in a screenshot. The new sweep walks whatever is on screen and lists both."),
                        ChangelogEntry(icon: "chart.line.uptrend.xyaxis", color: Color.stockedWarning,
                                       title: "Memory as a shape, not a number",
                                       detail: "The old reading was memory right now, which moves constantly and tells you nothing. It is now sampled across the whole session and drawn, with a plain answer at the top \u{2014} flat, settling, or growing \u{2014} and a list of the screens it grew on. That last part is what turns \u{201C}it gets slow after a while\u{201D} into something fixable."),
                        ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGreen,
                                       title: "Sending now says what went wrong",
                                       detail: "A report goes to as many as five places, and all you got back was \u{201C}2 of 4 destinations\u{201D} \u{2014} which two, and why not the others, thrown away as soon as it was known. Every destination's actual answer is kept now, so one broken setting is visible as one broken row instead of a number that will not say."),
                        ChangelogEntry(icon: "list.bullet.rectangle", color: Color.stockedGoldDark,
                                       title: "Name what you are testing",
                                       detail: "Start a run, call it what you are actually doing \u{2014} \u{201C}shopping list on the small phone\u{201D} \u{2014} and every report you file and every check you tick until you finish is grouped under that name, with its own summary to send. It turns a numbered report into a sentence somebody reading it next month can understand.")
                    ]),

                // ── 4.17 (build 73) — Testing mode gets out of your way ──
                ChangelogVersion(
                    version: "4.17",
                    buildDate: "Build 73 \u{00B7} July 27, 2026",
                    headline: "What's new in Stocked",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "lock.open.rotation", color: Color.stockedGold,
                                       title: "One passcode, ten minutes",
                                       detail: "Testing mode used to ask for the passcode every single time you opened it, including thirty seconds after you last typed it. One unlock now lasts ten minutes, and the menu tells you how long is left before it locks itself again. There is a Lock now button for when you want it shut immediately."),
                        ChangelogEntry(icon: "circle.circle.fill", color: Color.stockedGoldDark,
                                       title: "A floating button that follows you",
                                       detail: "Once you have been into testing mode, a small gold button sits above every screen \u{2014} including sheets and pop-ups \u{2014} and opens the whole menu wherever you are. Drag it anywhere; it stays put and clings to the nearest edge. It hides itself while you are writing a report so it can never end up in your own screenshot, and you can switch it off in the menu."),
                        ChangelogEntry(icon: "externaldrive.badge.icloud", color: Color.stockedGreen,
                                       title: "Reports land on your Mac by themselves",
                                       detail: "Every report now writes a real folder through iCloud Drive containing the written report, the screenshot, any mockup you attached and the notes meant for handing on \u{2014} grouped by build, with an index listing what is in each one. Pictures also upload to the server on a route built to carry them instead of being left behind, and if you run your own website there is now a small file you can install there to receive the same folders."),
                        ChangelogEntry(icon: "hand.tap.fill", color: Color.stockedInfo,
                                       title: "Screenshots can show where you tapped",
                                       detail: "Whoever reads the report can see the last few taps drawn straight onto the picture as numbered rings, so the path you took to the problem is visible rather than described. You can also turn on a live trail while you work. Both are off by default and live in the testing menu."),
                        ChangelogEntry(icon: "square.and.pencil", color: Color.stockedGold,
                                       title: "Fix a report and send it again",
                                       detail: "Reports were final once filed, which meant a typo or a detail you remembered afterwards had to become a second report. Any report can now be edited \u{2014} title, description and severity \u{2014} and re-sent everywhere it went the first time, keeping the original wording underneath if you want it. The report says how many times it has been changed and where each copy has reached."),
                        ChangelogEntry(icon: "wand.and.stars", color: Color.stockedGoldDark,
                                       title: "Attach a mockup, get the words written for you",
                                       detail: "You can add a picture of how you think a screen should look, from Files or from Photos. The report then writes two things by itself: a full brief for an image tool describing Stocked's colours, type and what is wrong with the screen today, and a matching brief for building the fix, complete with how you got there and what the app was doing at the time. Copy either with one tap; both are also saved into the report's folder."),
                    ]),
                // ── 4.16 (build 72) — What the first real test session found ──
                ChangelogVersion(
                    version: "4.16",
                    buildDate: "Build 72 \u{00B7} July 27, 2026",
                    headline: "What's new in Stocked",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "paperplane.circle.fill", color: Color.stockedGreen,
                                       title: "Reports you file now actually arrive",
                                       detail: "Every problem report filed on a phone was being turned away by the server and kept only on the device \u{2014} so a report you took the trouble to write never reached anyone. They now send correctly, and the server keeps them separately from the full health snapshot instead of one replacing the other."),
                        ChangelogEntry(icon: "moon.zzz.fill", color: Color.stockedGold,
                                       title: "Putting your phone down is not a freeze",
                                       detail: "Testing mode was timing how long the screen took to redraw, and it kept timing while the phone was locked or set aside. Coming back after a couple of minutes looked identical to the app hanging, and it filed serious-sounding reports about freezes that never happened. It now stops the stopwatch the moment the app leaves the screen, and treats any gap longer than ten seconds as what it plainly is."),
                        ChangelogEntry(icon: "hare.fill", color: Color.stockedGreen,
                                       title: "Cook Now got dramatically faster",
                                       detail: "Working out what you can cook slowed down far more sharply than the number of recipes grew \u{2014} ten times the recipes took over seventy times as long. Stocked now builds a quick word index of what is in your kitchen and skips the comparisons that could never match, so a full pass over every recipe finishes in a fraction of the time and the results are identical."),
                        ChangelogEntry(icon: "text.alignleft", color: Color.stockedGold,
                                       title: "Clearer reading of what went wrong",
                                       detail: "Report summaries no longer stop mid-word, each one says whether you filed it yourself or the app raised it on its own, and anything the server refused is now shown as refused rather than sitting quietly in a queue that will never clear."),
                    ]),
                // ── 4.15 (build 71) — Tell Stocked what went wrong ──
                ChangelogVersion(
                    version: "4.15",
                    buildDate: "Build 71 \u{00B7} July 27, 2026",
                    headline: "What's new in Stocked",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "exclamationmark.bubble.fill", color: Color.stockedError,
                                       title: "Press and hold to report a problem",
                                       detail: "While testing mode is on, holding your finger anywhere on the screen opens a short form: what went wrong, and how bad it is. It works on every screen, including ones with no obvious place to put a report button, and it does not interrupt whatever you were doing \u{2014} the app keeps behaving exactly as it would with testing mode off."),
                        ChangelogEntry(icon: "number.circle.fill", color: Color.stockedGold,
                                       title: "Every report gets its own number",
                                       detail: "Filing a report gives you a reference like STK-71-0004 straight away. That number appears in the session log, the activity trail, and the timing log, and it goes to the server with everything else, so a report you filed on a phone can be looked up later without anyone digging through screenshots."),
                        ChangelogEntry(icon: "camera.viewfinder", color: Color.stockedGreen,
                                       title: "Reports bring their own evidence",
                                       detail: "A report is filed with a picture of the screen as it looked when you pressed and held, plus the last twenty things you touched, what the app was busy doing, how much memory it was using, whether the phone was hot, and whether it was online. You describe the problem in a sentence and the rest is already attached."),
                        ChangelogEntry(icon: "bolt.horizontal.circle.fill", color: Color.stockedError,
                                       title: "Stocked notices its own stutters",
                                       detail: "Testing mode now measures how long each frame takes to draw. Anything slower than a tenth of a second is recorded with the screen it happened on, and anything that locks up for a full second files its own report without being asked \u{2014} because the moments worth catching are exactly the ones you cannot describe afterwards."),
                        ChangelogEntry(icon: "checkmark.seal.fill", color: Color.stockedGreen,
                                       title: "One verdict at the top",
                                       detail: "The testing screen used to be nine lists you had to read in order. It now opens with a single line \u{2014} ready to ship, or the number of things standing in the way \u{2014} and the things standing in the way, sorted worst first, with everything else still underneath."),
                        ChangelogEntry(icon: "arrow.counterclockwise.circle.fill", color: Color.stockedGold,
                                       title: "A testing session survives a crash",
                                       detail: "If the app closed unexpectedly, everything the session had recorded up to that moment used to vanish with it \u{2014} which is the one time you most wanted it. A snapshot is now saved as you go and offered back to you the next time you open the testing screen."),
                        ChangelogEntry(icon: "magnifyingglass", color: Color.stockedGold,
                                       title: "Search the session log",
                                       detail: "The activity list can be searched and filtered by kind, so finding the one failure in four hundred entries no longer means scrolling. Anything on the screen can be copied with a single tap."),
                        ChangelogEntry(icon: "eye.slash.fill", color: Color.stockedGold,
                                       title: "Screens nobody tried",
                                       detail: "Testing mode now lists screens you opened but never tapped anything on. It is a small thing that answers a question that used to need a spreadsheet: what did this round of testing actually cover?"),
                        ChangelogEntry(icon: "memorychip", color: Color.stockedGreen,
                                       title: "Memory and heat, watched live",
                                       detail: "Memory use, temperature, low power mode, free space, and failed network calls are sampled continuously while testing mode is on, so a report filed at the moment things went wrong carries the conditions that caused it. An optional one-line display can sit at the top or bottom of the screen \u{2014} it cannot be tapped and never takes a touch."),
                        ChangelogEntry(icon: "timer", color: Color.stockedGold,
                                       title: "Testing mode turns itself off",
                                       detail: "You can set it to stop after fifteen, thirty, or sixty minutes so it never gets left running for a week. It saves what it recorded on the way out."),
                        ChangelogEntry(icon: "square.and.arrow.up.fill", color: Color.stockedGreen,
                                       title: "One export with everything in it",
                                       detail: "Reports, stutters, memory, timings, checks, activity, and the crash log used to be six separate copies. One press now produces the whole picture as a single piece of text you can paste anywhere.")
                    ]
                ),
                // ── 4.14 (build 70) — Faster, and deletes that stay deleted ──
                ChangelogVersion(
                    version: "4.14",
                    buildDate: "Build 70 \u{00B7} July 27, 2026",
                    headline: "What's new in Stocked",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "bolt.fill", color: Color.stockedGreen,
                                       title: "Cook Now opens straight away",
                                       detail: "Tapping See meals could hang for several seconds or close the app outright. Stocked was working out whether every ingredient in every recipe matched something in your kitchen from scratch, over and over, for the same handful of words. It remembers those answers now, so the list appears immediately and scrolling stays smooth."),
                        ChangelogEntry(icon: "trash.fill", color: Color.stockedError,
                                       title: "Deleted grocery items stay deleted",
                                       detail: "Adding a recipe's missing ingredients and then swiping one away could bring the whole list back a moment later. A sync update already on its way still held the old list and quietly restored it. Deletions are now respected everywhere your list syncs, so gone means gone."),
                        ChangelogEntry(icon: "speedometer", color: Color.stockedGold,
                                       title: "Less work behind every screen",
                                       detail: "Recipe lists build their cards as you scroll to them rather than all at once, and screens that ask the same question several times now ask once. Everything that reads your kitchen shares the answer instead of recalculating it."),
                        ChangelogEntry(icon: "checkmark.seal.fill", color: Color.stockedGreen,
                                       title: "One place for QA",
                                       detail: "QA tools were scattered across a settings link, a second checklist link, and a floating bubble that followed you around the app. They are all in one screen now. (As of Build 74 that screen lives under Settings, Testing \u{2014} it is no longer inside App Health.)"),
                        ChangelogEntry(icon: "hand.tap.fill", color: Color.stockedGold,
                                       title: "QA counts that are actually counted",
                                       detail: "Taps, attempted actions, and failures all reported zero no matter how long a session ran, because nothing was feeding them. They record properly now."),
                        ChangelogEntry(icon: "list.bullet.rectangle.portrait.fill", color: Color.stockedGreen,
                                       title: "New process and flow tracker",
                                       detail: "QA mode now times everything the app is doing \u{2014} network calls, recipe matching passes, any flow that opts in \u{2014} and flags anything still running after two seconds. One export contains the taps, the actions, the timings, and the crash log together.")
                    ]
                ),
                // ── 4.13 (build 69) — Every screen agrees ──
                ChangelogVersion(
                    version: "4.13",
                    buildDate: "Build 69 · July 26, 2026",
                    headline: "What's new in Stocked",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "equal.circle.fill", color: Color.stockedGreen,
                                       title: "Every screen agrees on what you have",
                                       detail: "Cook, Recipes, Home, the widget, and your Daily Brief used to work out what was in your kitchen in slightly different ways, so the same pantry could look full on one screen and half-empty on another. They all read the same answer now."),
                        ChangelogEntry(icon: "checkmark.circle.badge.questionmark", color: Color.stockedGold,
                                       title: "More honest ingredient matching",
                                       detail: "Matching used to be loose enough that olive oil could stand in for any oil and garlic powder could pass as garlic. Cook percentages are stricter and truer now — if a recipe says you have everything, you have everything."),
                        ChangelogEntry(icon: "exclamationmark.shield.fill", color: Color.stockedError,
                                       title: "Allergens respected everywhere",
                                       detail: "Your saved allergens are now applied the same way across Cook, Recipes, Surprise Me, and recipe suggestions. The AI recipe generator can finally see them too, and will refuse a recipe that uses something you have listed."),
                        ChangelogEntry(icon: "clock.badge.checkmark", color: Color.stockedGold,
                                       title: "One meaning for low and expiring soon",
                                       detail: "Running low and expiring soon meant different things on different screens — a jar could be flagged in your grocery list but look fine in Inventory. One definition now, so alerts and lists match what you see."),
                        ChangelogEntry(icon: "text.badge.checkmark", color: Color.stockedGreen,
                                       title: "Missing-ingredient counts add up",
                                       detail: "Recipe cards could show a missing count that did not match the ingredients they named. The number and the list are built together now, and optional garnishes no longer count against a recipe."),
                        ChangelogEntry(icon: "sparkle.magnifyingglass", color: Color.stockedGreen,
                                       title: "Cook now ranks your whole recipe library",
                                       detail: "Cook only ever ranked your saved recipes and the built-in starters. Everything you browse in Recipes is now scored the same way, so Cook suggests real meals you have not saved yet, with readiness and substitutions worked out properly."),
                        ChangelogEntry(icon: "photo.stack.fill", color: Color.stockedGold,
                                       title: "Real photos on cook suggestions",
                                       detail: "Cook rows fell back to a plain icon whenever a recipe had no saved photo. They now show a real picture of the dish, looked up the same way the rest of the app does."),
                        ChangelogEntry(icon: "person.2.badge.key.fill", color: Color.stockedError,
                                       title: "Who you cook for actually counts",
                                       detail: "Allergies you record for the people in your household are now applied everywhere recipes are suggested, not just on the profile screen. Anyone marked as home has their allergies treated as a hard no."),
                        ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGold,
                                       title: "Generated recipes stay up to date",
                                       detail: "A recipe Stocked generated for you used to remember what was missing on the day it was created. It now checks against your kitchen as it is right now."),
                    ]
                ),
                // ── 4.13 (build 63) — Smoother, safer, connected ──
                ChangelogVersion(
                    version: "4.13",
                    buildDate: "Build 63 · July 17, 2026",
                    headline: "What's new in Stocked",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "pause.circle.fill", color: Color.stockedGold,
                                       title: "Pause a cook, come back later",
                                       detail: "Leaving mid-cook now asks what you want: pause, cancel, or keep going. A paused meal waits on the Cook screen and resumes at the exact step — timers included — even after closing the app."),
                        ChangelogEntry(icon: "lock.badge.clock", color: Color.stockedGreen,
                                       title: "Your plan protects its ingredients",
                                       detail: "Items reserved for planned meals now show Total, Reserved, and Available. Cooking something that borrows from a plan shows exactly which meal is affected — cook anyway, pick another, or add a replacement to the list."),
                        ChangelogEntry(icon: "doc.on.doc.fill", color: Color.stockedGold,
                                       title: "No more double groceries",
                                       detail: "Scanning a receipt after a shopping trip can't double-count your pantry anymore. Stocked spots likely duplicates, shows its evidence, and lets you merge, keep both, or skip."),
                        ChangelogEntry(icon: "cart.fill", color: Color.stockedGreen,
                                       title: "Shop by store",
                                       detail: "Group your grocery list by store, finish one store at a time, and move items between stores without retyping them."),
                        ChangelogEntry(icon: "wifi.slash", color: Color.stockedGold,
                                       title: "Offline that you can trust",
                                       detail: "Edits made offline queue up visibly — \"Pending changes · will sync\" — and send themselves exactly once when you're back online."),
                        ChangelogEntry(icon: "link.badge.plus", color: Color.stockedGreen,
                                       title: "Save recipes from social links",
                                       detail: "Paste a TikTok, Instagram, YouTube, or Pinterest link and review what Stocked found before saving. Anything uncertain is flagged for your eyes, never invented."),
                        ChangelogEntry(icon: "bell.slash.fill", color: Color.stockedGold,
                                       title: "Calmer notifications, faster opens",
                                       detail: "Reminders no longer pop over the app while you're using it, permission is asked once at the right moment, and launch is noticeably quicker. A rare crash on launch was also fixed."),
                    ]
                ),

                // ── 4.24 (build 44) — Adaptive cooking workspace ──
                ChangelogVersion(
                    version: "4.24",
                    buildDate: "Build 44 · July 14, 2026",
                    headline: "What's new in Stocked",
                    isLatest: false,
                    entries: [
                        ChangelogEntry(icon: "hand.raised.fill", color: Color.stockedGold,
                                       title: "Start With Something",
                                       detail: "Begin a cook with any ingredient, protein, leftover — or just an idea — and choose what to do with it. Make one thing, add a side, or build a full meal. Cooking one item is a complete cook; nothing pushes you toward a big dinner."),
                        ChangelogEntry(icon: "slider.horizontal.3", color: Color.stockedGreen,
                                       title: "Cooking methods that explain themselves",
                                       detail: "Compare ways to cook — sear then pressure cook, air fry, slow cook, and more — by what you actually get: texture, browning, effort, and time. Mark an appliance as dirty or in use and the options update instantly."),
                        ChangelogEntry(icon: "checklist", color: Color.stockedGold,
                                       title: "Before You Start",
                                       detail: "A quick setup checklist before any heat: the equipment you need, ingredients to pull with their locations, prep to knock out, and optional decisions — so nothing catches you off guard mid-cook."),
                        ChangelogEntry(icon: "timer", color: Color.stockedGreen,
                                       title: "Make the most of hands-off time",
                                       detail: "While something simmers or pressure cooks, add a side that fits the window, use a free appliance, or prep ahead — or do nothing at all. Resting is always a valid choice."),
                        ChangelogEntry(icon: "clock.arrow.circlepath", color: Color.stockedGold,
                                       title: "Cook ahead, finish later",
                                       detail: "Feeling motivated at lunchtime? Cook tonight's dinner early. It stays on your plan and moves to Finish & Serve with cooling, storage, and reheat guidance — cooking early only changes the cook time."),
                        ChangelogEntry(icon: "square.stack.3d.up.fill", color: Color.stockedGreen,
                                       title: "Prep once, use all week",
                                       detail: "Already cutting onions? If upcoming meals need them too, Stocked offers to prep extra now — with storage tips — so you save a step later."),
                    ]),
        // ── 4.23 (build 43) — Cook Now redesign: inventory-first dashboard ──
        ChangelogVersion(
            version: "4.23",
            buildDate: "Build 43 · July 14, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "gauge.with.dots.needle.67percent", color: Color.stockedGold,
                               title: "Cook Now leads with your kitchen",
                               detail: "The Cook tab now opens on a live dashboard: how many meals you can make right now, how many are missing just one or two items, and the top ingredients to build around — all calculated from what's actually logged."),
                ChangelogEntry(icon: "sparkles", color: Color.stockedGreen,
                               title: "Tonight's Pick",
                               detail: "Pick an ingredient (or ask to be surprised) and Stocked recommends one strong recipe first — with real reasons why — plus Try Another and See All Options one tap away."),
                ChangelogEntry(icon: "arrow.triangle.swap", color: Color.stockedGold,
                               title: "Honest substitutions",
                               detail: "Recipes that need a swap now say so up front. Review each substitution, see how to use it, and confirm it — or send the original to your grocery list instead."),
                ChangelogEntry(icon: "checklist", color: Color.stockedGreen,
                               title: "Kitchen Check and Prep First",
                               detail: "Before you cook, quickly confirm what you really have — corrections apply to tonight's meal without touching your inventory unless you say so — and knock out prep tasks pulled straight from the recipe."),
                ChangelogEntry(icon: "person.2.fill", color: Color.stockedGold,
                               title: "Serving sizes that follow you",
                               detail: "Your household size is applied automatically, adjustable right on the dashboard, and the count you choose carries through the recipe, scaling, and cooking — no more retyping it at every step."),
            ]),
        // ── 4.22 (build 42) — Assistant diagnostics, grocery names, deep lag fixes ──
        ChangelogVersion(
            version: "4.22",
            buildDate: "Build 42 · July 11, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "text.alignleft", color: Color.stockedGold,
                               title: "Grocery names finally read right",
                               detail: "Item names lead with the actual food — quantities and sizes baked into old names get split out automatically — and long names now truly glide across one line instead of cutting off."),
                ChangelogEntry(icon: "hare.fill", color: Color.stockedGreen,
                               title: "The big freeze hunt",
                               detail: "Fixed the stutter when opening the side menu (a photo was being re-decoded every frame) and the freezes on the Recipes tab (duplicate detection and pantry-ranking were re-running on every screen refresh). Both now compute once and stay cached."),
                ChangelogEntry(icon: "capsule", color: Color.stockedGold,
                               title: "Pill actually looks like a pill",
                               detail: "The Pill cook-button shape now uses fully rounded capsule rows, clearly distinct from the rounded photo cards."),
                ChangelogEntry(icon: "stethoscope", color: Color.stockedGreen,
                               title: "The kitchen assistant tells you what is wrong",
                               detail: "Assistant errors now report the exact server-side cause, and the server has a health check that shows whether its keys are configured."),
            ]),
        // ── 4.21 (build 41) — Build fix, worker health, smart grocery quantities ──
        ChangelogVersion(
            version: "4.21",
            buildDate: "Build 41 · July 11, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "cart.badge.plus", color: Color.stockedGold,
                               title: "Grocery quantities add themselves up",
                               detail: "When two recipes and a manual add all call for onions, the list shows one row with the right total — 4 plus 3 plus 1 makes 8. Measured items like a 14 oz sauce show their size right on the row."),
                ChangelogEntry(icon: "text.alignleft", color: Color.stockedGreen,
                               title: "Long names glide, never wrap",
                               detail: "Grocery item names always stay on one line — if a name is too long, it gently scrolls to show the rest."),
                ChangelogEntry(icon: "exclamationmark.triangle", color: Color.stockedGold,
                               title: "Clearer error messages",
                               detail: "When the kitchen assistant can't be reached, Stocked now tells you exactly why — and error messages no longer wear a green checkmark."),
                ChangelogEntry(icon: "hare.fill", color: Color.stockedGreen,
                               title: "Recipe browsing, unfrozen",
                               detail: "Recipe matching against your pantry is now cached, eliminating the biggest cause of stutter when scrolling and sorting large recipe collections."),
            ]),
        // ── 4.20 (build 40) — Cook button fix + app-wide speed pass ──
        ChangelogVersion(
            version: "4.20",
            buildDate: "Build 40 · July 11, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "slider.horizontal.3", color: Color.stockedGold,
                               title: "Cook buttons truly resize now",
                               detail: "The Cook Buttons setting finally controls the real Cook page: shape switches between circles, photo cards, and compact rows, and the size slider grows or shrinks them live — always centered."),
                ChangelogEntry(icon: "hare.fill", color: Color.stockedGreen,
                               title: "Faster everywhere",
                               detail: "A speed pass across the app: the Cook page, inventory, grocery list, and Daily Brief now do their heavy thinking once instead of on every frame, and long lists load rows as you scroll. Scrolling and tab switches feel noticeably snappier."),
            ]),
        // ── 4.19 (build 39) — Redesigned Settings page ──
        ChangelogVersion(
            version: "4.19",
            buildDate: "Build 39 · July 11, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "gearshape.fill", color: Color.stockedGold,
                               title: "A brand-new Settings home",
                               detail: "Everything settings-shaped now lives on one beautiful page — tap Settings in the side menu. Preferences, Notifications, Data & Storage, your Account, and Help each expand in place, so nothing is more than two taps away."),
                ChangelogEntry(icon: "sidebar.left", color: Color.stockedGreen,
                               title: "A lighter side menu",
                               detail: "The drawer is now just your tools and insights — the long settings list moved to the new Settings page, including Log Out, Delete Account, and the Help Center."),
            ]),
        // ── 4.18 (build 38) — Improvements batch 3: onboarding, audit, and household polish ──
        ChangelogVersion(
            version: "4.18",
            buildDate: "Build 38 · July 11, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.tap.fill", color: Color.stockedGold,
                               title: "Fill an empty pantry in seconds",
                               detail: "A brand-new kitchen now offers a tap-to-add grid of twenty common staples right on the empty pantry screen, alongside receipt scanning — no typing required."),
                ChangelogEntry(icon: "checkmark.seal", color: Color.stockedGreen,
                               title: "Pantry Audit",
                               detail: "New in Kitchen Tools: sweep through everything Stocked hasn't seen you touch in a while and confirm, mark used, or restock each in one tap. Ten minutes resets your whole kitchen to truth."),
                ChangelogEntry(icon: "person.crop.circle.badge.checkmark", color: Color.stockedGold,
                               title: "Assignments now sync to your household",
                               detail: "Grocery items you assign to family members now show up for everyone, and a new Mine filter shows just your items plus anything unassigned."),
                ChangelogEntry(icon: "plus.circle", color: Color.stockedGold,
                               title: "Add items with Siri",
                               detail: "Say Add an item to Stocked and it lands in your kitchen the next time you open the app — joining the mark-as-used command from last update."),
                ChangelogEntry(icon: "clock.arrow.circlepath", color: Color.stockedGreen,
                               title: "Smarter grocery suggestions",
                               detail: "The grocery list now suggests staples you're probably running low on based on your own usage rhythm, a new Needs Check sort surfaces items to verify, and merging duplicates adds amounts correctly across units like grams and pounds."),
            ]),
        // ── 4.17 (build 37) — Improvements batch 2: profile, planning, and voice ──
        ChangelogVersion(
            version: "4.17",
            buildDate: "Build 37 · July 11, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "leaf.circle", color: Color.stockedGreen,
                               title: "Your dietary profile, applied everywhere",
                               detail: "Set your diet and allergens once in Kitchen Tools > Dietary Profile. Recipe browsing hides allergen conflicts by default and AI recipe ideas respect your diet automatically."),
                ChangelogEntry(icon: "speaker.wave.2", color: Color.stockedGold,
                               title: "Recipes read steps aloud",
                               detail: "Every instruction step now has a speaker button — one tap reads it out loud for flour-covered hands."),
                ChangelogEntry(icon: "calendar.badge.checkmark", color: Color.stockedGreen,
                               title: "Planned ingredients are marked",
                               detail: "Items committed to an upcoming planned meal show a small planned tag in your inventory, so you never plan two dinners around the same onion."),
                ChangelogEntry(icon: "person.badge.plus", color: Color.stockedGold,
                               title: "Assign grocery items to family",
                               detail: "Long-press any grocery item to assign it to a household member — everyone sees who's grabbing what."),
                ChangelogEntry(icon: "mic.circle", color: Color.stockedGold,
                               title: "Tell Siri when you finish something",
                               detail: "Say something like Mark an item used in Stocked and it's marked used the next time you open the app. Scaled recipes also now add the right amounts to your grocery list."),
                ChangelogEntry(icon: "questionmark.bubble", color: Color.stockedGreen,
                               title: "Stocked learns why food goes to waste",
                               detail: "When something goes to waste, the Daily Brief asks one quick question — bought too much, forgot it, or plans changed — and tailors its advice to your answer. Expiry dates also get smarter defaults learned from the community."),
            ]),
        // ── 4.16 (build 36) — Improvements batch 1: drift-proofing + smarter data ──
        ChangelogVersion(
            version: "4.16",
            buildDate: "Build 36 · July 11, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal", color: Color.stockedGreen,
                               title: "Pantry Check keeps your kitchen honest",
                               detail: "The Daily Brief now asks about items it hasn't seen you touch in a while — one tap says Yes, Used it, or Ran out, so your inventory stays true to your real kitchen."),
                ChangelogEntry(icon: "clock.arrow.circlepath", color: Color.stockedGold,
                               title: "Stocked learns how fast you go through things",
                               detail: "Based on your own usage history, the Daily Brief predicts staples you're about to run out of — like milk every five days — and adds them to your list in one tap."),
                ChangelogEntry(icon: "arrow.triangle.merge", color: Color.stockedGold,
                               title: "Smarter duplicate merging",
                               detail: "Adding Chicken Breasts when you already have chicken breast now updates one item instead of creating two — and 500 g plus 1 lb of the same thing adds up correctly."),
                ChangelogEntry(icon: "cart.badge.questionmark", color: Color.stockedGold,
                               title: "No more triple-buying chickpeas",
                               detail: "Adding something to your grocery list that's already stocked shows a friendly heads-up with how many you have."),
                ChangelogEntry(icon: "dollarsign.circle", color: Color.stockedGreen,
                               title: "See what you saved",
                               detail: "The Kitchen Report now celebrates the wins: items used before they went bad, your use-it rate for the month, and what waste actually cost you."),
                ChangelogEntry(icon: "doc.text.viewfinder", color: Color.stockedGold,
                               title: "Faster first fill-up",
                               detail: "An empty pantry now leads with the quickest way to fill it — scan a grocery receipt and everything's added at once. New recipes with jumbled steps also get cleaned up automatically."),
            ]),
        // ── 4.15 (build 35) — Cook buttons, Daily Brief, recipe cleanup ──
        ChangelogVersion(
            version: "4.15",
            buildDate: "Build 35 · July 11, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "slider.horizontal.3", color: Color.stockedGold,
                               title: "Cook buttons resize everywhere",
                               detail: "The size and shape options in the side menu now change the Cook Now and Cook Later buttons too — they grow, shrink, and reshape live while staying perfectly centered."),
                ChangelogEntry(icon: "person.3.fill", color: Color.stockedGreen,
                               title: "Daily Brief shows real household activity",
                               detail: "When you're in a household, the brief now shows what your family actually did — who added, checked off, or updated items — instead of a rough guess."),
                ChangelogEntry(icon: "hand.tap", color: Color.stockedGold,
                               title: "Everything in the Daily Brief works",
                               detail: "Every number and stat in the brief is now a shortcut: tap expiring or low stock to see those items, tap meals to jump to Cook, and use the new Quick Actions to scan a receipt or barcode right from the brief."),
                ChangelogEntry(icon: "wand.and.stars", color: Color.stockedGold,
                               title: "Recipe instructions, cleaned up",
                               detail: "Blank or broken steps no longer appear in your recipes. If a recipe's instructions still look off, tap Fix with AI on the recipe page and Stocked will rewrite them into clear, ordered steps."),
            ]),
        // ── 4.14 (build 34) — Tap target fix on cards ──
        ChangelogVersion(
            version: "4.14",
            buildDate: "Build 34 · July 11, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.tap", color: Color.stockedGold,
                               title: "Cards tap where you tap",
                               detail: "Fixed the photo cards on the Cook screens, like Build Around Food, where tapping the bottom of a card could open the next one. Every card now responds anywhere inside it and never triggers its neighbor."),
            ]),
        // ── 4.13 (build 32) — API Ninjas recipes wired in ──
        ChangelogVersion(
            version: "4.13",
            buildDate: "Build 33 · July 7, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "fork.knife.circle", color: Color.stockedGold,
                               title: "More recipes from API Ninjas",
                               detail: "When an API Ninjas key is configured, Stocked now pulls general recipes from it to help fill the recipe tabs, seeded by your cuisine preferences and what is in your kitchen, in addition to its cocktails."),
            ]),
        // ── 4.12 (build 31) — Login hardening, tidy Data & Storage ──
        ChangelogVersion(
            version: "4.12",
            buildDate: "Build 31 · July 7, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "lock.shield", color: Color.stockedGold,
                               title: "Two clear ways in",
                               detail: "The login screen now has exactly two paths: Sign in with Apple, or continue as a guest with your name. Guest entry asks for a name, and signing out always brings you back to this screen — even after closing the app."),
                ChangelogEntry(icon: "internaldrive", color: Color.stockedGold,
                               title: "Tidier Data & Storage",
                               detail: "Duplicate rows in Data and Storage were combined. One clean list now covers transferring your kitchen, backing up to iCloud, storage and auto backup, deleting iCloud data, and clearing the app."),
            ]),
        // ── 4.11 (build 30) — Quick Update understands brands and clear-all ──
        ChangelogVersion(
            version: "4.11",
            buildDate: "Build 30 · July 7, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "text.bubble", color: Color.stockedGold,
                               title: "Quick Update understands brands and amounts",
                               detail: "Say you used the lemon pepper and Quick Update matches it to your Hill Country Fare Lemon Pepper. It also reads quantities and units now, so bought three cans of black beans or a 24 oz bag of rice records the count and size, and used two cans lowers the count instead of removing everything."),
                ChangelogEntry(icon: "trash", color: Color.stockedGold,
                               title: "Clear everything by asking",
                               detail: "Tell Quick Update to clear all your inventory, wipe everything, or start over, and it will offer to empty your inventory for review. This works instantly, even offline."),
                ChangelogEntry(icon: "wifi.slash", color: Color.stockedGold,
                               title: "Works first time, and offline",
                               detail: "Quick Update now opens the review sheet on the first send instead of needing a second try, and common updates like adding items, finishing an item, or running low work right on your device even when you are offline."),
            ]),
        // ── 4.10 (build 29) — Sources browser shows only sources with results ──
        ChangelogVersion(
            version: "4.10",
            buildDate: "Build 29 · July 7, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "line.3.horizontal.decrease.circle", color: Color.stockedGold,
                               title: "Sources that deliver, only",
                               detail: "The Sources browser now lists only sources that actually have recipes on your device, with live counts. No more tapping into empty screens — websites appear the moment their first recipe arrives."),
                ChangelogEntry(icon: "key.slash", color: Color.stockedGold,
                               title: "Keyed feeds hide until configured",
                               detail: "Feeds that need credentials, like Edamam, Tasty, and API Ninjas, stay hidden until their keys are set up, so the list never promises what it can't show."),
                ChangelogEntry(icon: "internaldrive.badge.checkmark", color: Color.stockedGold,
                               title: "Counts include your device library",
                               detail: "Source counts and per-source lists now include everything in your on-device recipe database — ingested, synced, or imported — with duplicates folded together."),
            ]),
        // ── 4.9 (build 28) — Storage reliability fix and fuller recipe tabs ──
        ChangelogVersion(
            version: "4.9",
            buildDate: "Build 28 · July 7, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "internaldrive", color: Color.stockedGold,
                               title: "Storage reliability fix",
                               detail: "Fixed an issue that could stop the new on-device recipe store from loading on some devices, which meant it quietly fell back to temporary storage. It now loads reliably and keeps your data between launches."),
                ChangelogEntry(icon: "square.grid.3x3.fill", color: Color.stockedGold,
                               title: "Fuller recipe tabs",
                               detail: "Every recipe area now pulls from more sources and more categories each refresh, so Discover, Browse, and the Sources and Drinks sections fill up with far more recipes."),
                ChangelogEntry(icon: "carrot", color: Color.stockedGold,
                               title: "Recipes for what you have",
                               detail: "Discover now also pulls recipes built around ingredients already in your kitchen, so there is always something you can actually make."),
                ChangelogEntry(icon: "gauge.with.dots.needle.67percent", color: Color.stockedGold,
                               title: "Smoother loading",
                               detail: "Recipe fetching is paced so it stops hitting rate limits, which means fewer stalls and more recipes loaded on each refresh."),
            ]),
        // ── 4.8 (build 27) — Three more drink sources for the Drinks section ──
        ChangelogVersion(
            version: "4.8",
            buildDate: "Build 27 · July 7, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "wineglass.fill", color: Color.stockedGold,
                               title: "Three new drink sources",
                               detail: "The Drinks section now pours from four places at once: TheCocktailDB, the IBA's 77 official cocktails, the Open Drinks community database, and API Ninjas. Pull down and every source refreshes together."),
                ChangelogEntry(icon: "checkmark.seal", color: Color.stockedGold,
                               title: "The official classics, offline",
                               detail: "The full IBA official cocktail list is fetched once and kept on your device, so the classics — Negroni, Vesper, Old Fashioned and all — are always available, even with no connection."),
                ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGold,
                               title: "Drinks join the shared library",
                               detail: "Every drink fetched from any source syncs into your on-device recipe pool, so search, Discover, and the Sources browser all see them too."),
            ]),
        // ── 4.7 (build 26) — Sources browser, Drinks, 30 sources, coach marks ──
        ChangelogVersion(
            version: "4.7",
            buildDate: "Build 26 · July 7, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "globe", color: Color.stockedGold,
                               title: "Browse recipes by source",
                               detail: "A new Sources card on the Recipes tab lists every place recipes come from — live feeds and dozens of websites, including ones you add — with live counts. Tap any source to see its recipes."),
                ChangelogEntry(icon: "wineglass", color: Color.stockedGold,
                               title: "The Drinks section",
                               detail: "Cocktails, mocktails, coffees, shakes, and party drinks now have their own home on the Recipes tab, grouped by type. Pull down to fetch a fresh round."),
                ChangelogEntry(icon: "plus.rectangle.on.rectangle", color: Color.stockedGold,
                               title: "30 more recipe sources",
                               detail: "Thirty new sites join the catalogue — BBC Good Food, Serious Eats, Bon Appétit, Budget Bytes, The Woks of Life, Smitten Kitchen, and many more — everywhere sources appear."),
                ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGold,
                               title: "Sources now work together",
                               detail: "Every recipe fetched from any source now joins one shared on-device pool, so search, Match My Mood, Discover, and cook suggestions all draw from the same growing library — even offline."),
                ChangelogEntry(icon: "lightbulb", color: Color.stockedGold,
                               title: "Updated tips",
                               detail: "The guided tips on every tab now cover the newest features: pull to refresh, swipe to delete, the Kitchen Toolbox, Sources, and Drinks."),
            ]),
        // ── 4.6 (build 25) — Pull to refresh, polish, mood fix, Health sync ──
        ChangelogVersion(
            version: "4.6",
            buildDate: "Build 25 · July 7, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.clockwise", color: Color.stockedGold,
                               title: "Pull to refresh, everywhere",
                               detail: "Pull down on any screen to refresh. If you share a household, it also pulls the latest changes from everyone right away."),
                ChangelogEntry(icon: "theatermasks", color: Color.stockedGold,
                               title: "Match My Mood always delivers",
                               detail: "Your mood match now checks the web, your built-in recipe database, and AI in turn — so you always land on a recipe, even offline. Your energy and time answers now shape the pick too."),
                ChangelogEntry(icon: "calendar.badge.plus", color: Color.stockedGold,
                               title: "Plan a Meal fixed",
                               detail: "The Plan a Meal button in Cook Later now opens the weekly planner as intended, along with the empty-state shortcut."),
                ChangelogEntry(icon: "heart.fill", color: Color.stockedGold,
                               title: "Apple Health sync",
                               detail: "Turn on Apple Health in Preferences and every meal you finish cooking logs its estimated nutrition — calories, protein, carbs, and fat — to Health automatically."),
                ChangelogEntry(icon: "person.crop.circle.badge.checkmark", color: Color.stockedGold,
                               title: "Cleaner sign-in and sign-out",
                               detail: "Signing out now fully clears the previous profile from the app. Signing back in with Apple restores your name and details automatically, and review sheets across the app now open reliably on the first tap."),
            ]),
        // ── 4.5 (build 24) — Drawer customization, swipe delete, recipe sources ──
        ChangelogVersion(
            version: "4.5",
            buildDate: "Build 24 · July 7, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.draw", color: Color.stockedGold,
                               title: "Rearrange your menu",
                               detail: "Press and hold any item under Kitchen Tools or Insights in the side menu, then drag it into the order you like. Kitchen Toolbox now lives under Kitchen Tools by default."),
                ChangelogEntry(icon: "trash.slash", color: Color.stockedGold,
                               title: "Swipe to delete",
                               detail: "Swipe left on any item in your inventory, your grocery list, or the low-stock suggestions to remove it. Deletes from your lists can be undone right away."),
                ChangelogEntry(icon: "globe", color: Color.stockedGold,
                               title: "Add your own recipe sites",
                               detail: "Open Recipe Sources from the side menu to add any recipe website, or add a suggested one with a single tap. Your sites join the built-in list everywhere recipes are pulled."),
                ChangelogEntry(icon: "icloud.slash", color: Color.stockedGold,
                               title: "Delete iCloud data",
                               detail: "A new option under Data and Storage removes every backup stored in your iCloud account, without touching the data on your device."),
            ]),
        // ── 4.4 (build 23) — Kitchen Toolbox: 20 new tools ────────────────────
        ChangelogVersion(
            version: "4.4",
            buildDate: "Build 23 · July 7, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "wrench.and.screwdriver", color: Color.stockedGold,
                               title: "Meet the Kitchen Toolbox",
                               detail: "A new hub in the side menu with 20 tools: Pantry Value, Expiry Calendar, Waste Insights, Weekly Review, Low Stock Report, Price Lookup, and more. Search finds any tool by name."),
                ChangelogEntry(icon: "square.stack.3d.up", color: Color.stockedGold,
                               title: "Plan and shop smarter",
                               detail: "Scale a recipe for batch cooking and shop for the whole batch, save your grocery list as a reusable template, set a monthly grocery budget, and see roughly what a recipe costs to make."),
                ChangelogEntry(icon: "dice", color: Color.stockedGold,
                               title: "Cook with less friction",
                               detail: "Spin the Recipe Roulette when you can't decide, run up to four kitchen timers at once, convert cups to grams for any ingredient, and get ideas for tonight's leftovers."),
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Keep things tidy",
                               detail: "Find and merge duplicate inventory items (with undo), look up how long foods last, browse storage tips and seasonal produce, share a snapshot of your pantry, and earn kitchen badges."),
            ]),
        // ── 4.3 (build 22) — Build Around Food fix, receipt restock, stats ────
        ChangelogVersion(
            version: "4.3",
            buildDate: "Build 22 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.tap", color: Color.stockedGold,
                               title: "Build Around Food cards work again",
                               detail: "Tapping Proteins, Vegetables, Expiring Soon, or Leftovers now opens the category as expected. They had stopped responding to taps."),
                ChangelogEntry(icon: "checklist", color: Color.stockedGold,
                               title: "Receipts tidy your grocery list",
                               detail: "After you scan a receipt, anything you bought that was on your grocery list gets checked off automatically."),
                ChangelogEntry(icon: "chart.bar", color: Color.stockedGold,
                               title: "Kitchen Stats and Sync Diagnostics",
                               detail: "A new Kitchen Stats view shows what you use, waste, and cook most, and a Sync Diagnostics screen shows your household sync status at a glance."),
            ]),
        // ── 4.2 (build 21) — planner, permissions, recipe photos, leftovers ───
        ChangelogVersion(
            version: "4.2",
            buildDate: "Build 21 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "calendar", color: Color.stockedGold,
                               title: "Shared weekly meal planner",
                               detail: "Plan meals for the week and mark them cooked. Your plan syncs with everyone in the household, just like your pantry and recipes."),
                ChangelogEntry(icon: "photo", color: Color.stockedGold,
                               title: "Recipe photos sync",
                               detail: "Photos on the recipes you create and save now sync to the whole household, so everyone sees the same picture."),
                ChangelogEntry(icon: "slider.horizontal.3", color: Color.stockedGold,
                               title: "Fine-grained member permissions",
                               detail: "Owners can now toggle add, edit, and remove for each member individually, and those limits are enforced everywhere, not just hidden in the app."),
                ChangelogEntry(icon: "takeoutbag.and.cup.and.straw", color: Color.stockedGold,
                               title: "Leftovers and smart use-by dates",
                               detail: "Cooked meals can be saved as leftovers in your fridge, and items added without a date now get a smart use-by estimate so nothing slips past expiry unnoticed."),
            ]),
        // ── 4.1 (build 20) — sync speed, activity feed, smarter staples ───────
        ChangelogVersion(
            version: "4.1",
            buildDate: "Build 20 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "bolt.horizontal", color: Color.stockedGold,
                               title: "Household changes sync in seconds",
                               detail: "Shared pantries now update within a few seconds instead of waiting for a slower cycle, and it stays light on data by only fetching what actually changed."),
                ChangelogEntry(icon: "list.bullet.rectangle", color: Color.stockedGold,
                               title: "See who changed what",
                               detail: "The Household Activity feed now shows items and recipes as they're added, edited, and removed by each member."),
                ChangelogEntry(icon: "exclamationmark.triangle", color: Color.stockedGold,
                               title: "Fewer surprises when changes collide",
                               detail: "If someone deletes an item while you're editing it, Stocked now asks you what to do instead of silently dropping your change. Sync also backs off and retries calmly when the connection is flaky."),
                ChangelogEntry(icon: "cart.badge.plus", color: Color.stockedGold,
                               title: "Smarter staple suggestions",
                               detail: "Stocked can now spot staples you tend to run out of on a regular cycle and suggest re-adding them before you're out."),
            ]),
        // ── 4.0 (build 19) — conflict review ──────────────────────────────────
        ChangelogVersion(
            version: "4.0",
            buildDate: "Build 19 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "exclamationmark.triangle", color: Color.stockedGold,
                               title: "You choose when changes collide",
                               detail: "If two people change the same item or recipe while offline, Stocked no longer silently picks one. Household Settings shows a Review Changes card where you pick which version to keep, so an edit you made is never quietly lost."),
            ]),
        // ── 3.9 (build 18) — household recipe sync ────────────────────────────
        ChangelogVersion(
            version: "3.9",
            buildDate: "Build 18 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "book.closed", color: Color.stockedGold,
                               title: "Your household shares a recipe collection",
                               detail: "Recipes you create and AI recipes you save now sync to everyone in your household, so you all see the same collection. Edits and deletions sync too. Recipe photos stay on the device that added them for now."),
            ]),
        // ── 3.8 (build 17) — visible sync status + Sync Now ───────────────────
        ChangelogVersion(
            version: "3.8",
            buildDate: "Build 17 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.circle", color: Color.stockedGold,
                               title: "See your household sync status",
                               detail: "Household Settings now shows whether you're up to date, when you last synced, and how many changes are waiting. A Sync Now button lets you sync on demand instead of waiting for the automatic cycle."),
            ]),
        // ── 3.7 (build 16) — durable offline sync queue ───────────────────────
        ChangelogVersion(
            version: "3.7",
            buildDate: "Build 16 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "tray.and.arrow.up", color: Color.stockedGold,
                               title: "Offline household changes never get lost",
                               detail: "Changes you make while offline are now saved to a durable queue and sync automatically the next time you're connected, even if you quit the app in between. Adds, edits, and removals all catch up on their own."),
            ]),
        // ── 3.6 (build 15) — household sync reliability fix ───────────────────
        ChangelogVersion(
            version: "3.6",
            buildDate: "Build 15 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGold,
                               title: "Household sync now updates reliably both ways",
                               detail: "Fixed an issue where a sync in progress could block the next one and leave your shared pantry from updating. Changes you and other members make now flow in both directions on their own."),
            ]),
        // ── 3.5 (build 14) — full household sharing ───────────────────────────
        ChangelogVersion(
            version: "3.5",
            buildDate: "Build 14 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "house.and.flag", color: Color.stockedGold,
                               title: "Households sync automatically, both ways",
                               detail: "Once people are in a household, your shared pantry and lists stay in sync on their own. Adding, removing, changing an item, its quantity, or its name now shows up for everyone, with no manual sync button. Changes made while you were away appear when you open the app."),
                ChangelogEntry(icon: "person.2.badge.gearshape", color: Color.stockedGold,
                               title: "Owner controls for members",
                               detail: "The household owner can set each member's access level (Kid, Teen, Adult, or Manager), give them a custom label like Mom or Big Sis, and control what they're allowed to change. Kids can view, teens and up can add and edit, adults can remove, and managers can help run the household."),
            ]),
        // ── 3.4 (build 13) — Sign in with Apple after clearing data ───────────
        ChangelogVersion(
            version: "3.4",
            buildDate: "Build 13 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "person.crop.circle.badge.checkmark", color: Color.stockedGold,
                               title: "Signing in with Apple works after clearing data",
                               detail: "If you cleared your data and then signed in with your Apple ID, the app could leave you shown as Chef in guest mode and send you back through the onboarding quiz. Signing in now completes properly, keeps you as your account, and skips the quiz."),
            ]),
        // ── 3.3 (build 12) — Clear All Data fully erases ──────────────────────
        ChangelogVersion(
            version: "3.3",
            buildDate: "Build 12 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "trash", color: Color.stockedGold,
                               title: "Clear All Data now fully clears",
                               detail: "Erasing your data now removes everything, including larger inventories that were stored on disk and could previously reappear after clearing. When it says cleared, it stays cleared, including when you choose Erase and Exit on logout."),
            ]),
        // ── 3.2 (build 11) — household sync + duplicate-check fix ──────────────
        ChangelogVersion(
            version: "3.2",
            buildDate: "Build 11 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGold,
                               title: "Household items actually sync now",
                               detail: "Items you add to your inventory now show up for everyone in your household, and changes push automatically instead of only when you manually sync. Before, an item you added stayed on your own device and the other person never saw it."),
                ChangelogEntry(icon: "checkmark.circle", color: Color.stockedGold,
                               title: "No more false duplicate warnings",
                               detail: "Adding an item no longer warns that it is already in your kitchen just because its name appears inside an unrelated product. For example, adding Milk no longer matches Eggo Buttermilk Waffles."),
            ]),
        // ── 3.1 (build 10) — household invite fix ─────────────────────────────
        ChangelogVersion(
            version: "3.1",
            buildDate: "Build 10 · July 1, 2026",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "person.2.badge.plus", color: Color.stockedGold,
                               title: "Inviting people to your household works",
                               detail: "Joining a household with an invite code now correctly adds that person as a separate member. Before, if both devices had the same default name they were treated as one person and the new member silently never appeared. Each device now keeps its own identity."),
            ]),
        // ── 2.6 (build 5) — feature round-up + guided tour ────────────────────
        ChangelogVersion(
            version: "2.6",
            buildDate: "Build 5 · June 30, 2026 at 3:30 AM",
            headline: "What's new in Stocked",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Create recipes with AI",
                               detail: "From the Recipes screen, tap Create with AI, describe what you want, and Stocked builds a full recipe. List ingredients you have and pick a dietary preference or time limit to tailor it. Saved AI recipes appear in Saved alongside everything else."),
                ChangelogEntry(icon: "wand.and.stars", color: Color.stockedGold,
                               title: "Inventory Assistant",
                               detail: "On the Inventory screen, tap Inventory Assistant and say what changed in plain words: use up an item, set a level, add something you bought, or clear everything. You confirm every change before it applies."),
                ChangelogEntry(icon: "cart.badge.plus", color: Color.stockedGold,
                               title: "Move items to your grocery list",
                               detail: "Press and hold an inventory item to move it to the grocery list, with an undo if you change your mind."),
                ChangelogEntry(icon: "questionmark.circle", color: Color.stockedGold,
                               title: "Updated guided tour",
                               detail: "The in-app tour now points out the new AI features so they are easy to find."),
            ]),
        // ── 2.5 (build 4) — AI inventory assistant ────────────────────────────
        ChangelogVersion(
            version: "2.5",
            buildDate: "Build 4 · June 30, 2026 at 3:00 AM",
            headline: "Change inventory by asking",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Inventory Assistant",
                               detail: "On the Inventory screen, tap Inventory Assistant and say what changed in plain words: use up an item, set a level, add something you bought, or clear everything. You review and confirm every change before it is applied, and clearing all can be undone."),
            ]),
        // ── 2.4 (build 4) — saved AI recipes + move to grocery ────────────────
        ChangelogVersion(
            version: "2.4",
            buildDate: "Build 4 · June 30, 2026 at 2:30 AM",
            headline: "Saved recipes and quick grocery moves",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "tray.full.fill", color: Color.stockedGold,
                               title: "AI recipes now show up in Saved",
                               detail: "Saving an AI-generated recipe now adds it to your recipe collection, so it appears in Saved and counts toward Favorites, Cooked, and Collections like any other recipe."),
                ChangelogEntry(icon: "cart.badge.plus", color: Color.stockedGold,
                               title: "Move an item straight to your grocery list",
                               detail: "Press and hold an inventory item to move it to the grocery list. It leaves your inventory and lands on your shopping list, with an undo if you change your mind."),
            ]),
        // ── 2.3 (build 4) — Create with AI in the hub grid ────────────────────
        ChangelogVersion(
            version: "2.3",
            buildDate: "Build 4 · June 30, 2026 at 2:00 AM",
            headline: "Create with AI, front and center",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Create with AI is now in the Recipes grid",
                               detail: "Categories is now the same size as the other cards, and Create with AI sits right below Collections as the sixth card. Tapping it goes straight to the recipe generator."),
            ]),
        // ── 2.2 (build 4) — reach AI from the Recipes screen ──────────────────
        ChangelogVersion(
            version: "2.2",
            buildDate: "Build 4 · June 30, 2026 at 1:30 AM",
            headline: "Create a recipe right from Recipes",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "plus.circle.fill", color: Color.stockedGold,
                               title: "Create Recipe is now on the Recipes screen",
                               detail: "Added a Create Recipe button to the Recipes screen that opens the create menu, including Create with AI. Before, the create options were only reachable from a sub-screen."),
            ]),
        // ── 2.0.1 (build 4) — AI recipe generation ────────────────────────────
        ChangelogVersion(
            version: "2.0.1",
            buildDate: "Build 4 · June 30, 2026 at 1:00 AM",
            headline: "Create recipes with AI",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Describe it, and Stocked builds it",
                               detail: "New in the recipe create menu: describe what you want, list ingredients you have, pick a dietary preference and a time limit, and Stocked generates a full recipe you can review and save."),
            ]),
        // ── 1.14 (build 3) — global search fixes ──────────────────────────────
        ChangelogVersion(
            version: "1.14",
            buildDate: "Build 3 · June 29, 2026 at 11:45 PM",
            headline: "Search bar fixes",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "magnifyingglass", color: Color.stockedGold,
                               title: "Search works the way it should",
                               detail: "The search bar no longer hides under the status bar, the Cancel button now closes search, and the search field matches dark mode."),
            ]),
        // ── 1.13 (build 3) — daily brief dark mode + greeting ─────────────────
        ChangelogVersion(
            version: "1.13",
            buildDate: "Build 3 · June 29, 2026 at 11:15 PM",
            headline: "Daily Brief fixes",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sun.max.fill", color: Color.stockedGold,
                               title: "Daily Brief looks right in dark mode",
                               detail: "The brief's stats card was showing a bright white panel in dark mode. It now uses a dark card with readable text. The brief also no longer repeats the greeting that's already on your home screen."),
            ]),
        // ── 1.12 (build 3) — more concurrency warnings ────────────────────────
        ChangelogVersion(
            version: "1.12",
            buildDate: "Build 3 · June 29, 2026 at 10:45 PM",
            headline: "Build hygiene, continued",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "wrench.and.screwdriver.fill", color: Color.stockedGold,
                               title: "Fewer build warnings",
                               detail: "Cleared more concurrency warnings and a deprecation, with no change to how the app looks or works."),
            ]),
        // ── 1.11 (build 3) — concurrency warnings cleanup ─────────────────────
        ChangelogVersion(
            version: "1.11",
            buildDate: "Build 3 · June 29, 2026 at 10:15 PM",
            headline: "Build hygiene",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "wrench.and.screwdriver.fill", color: Color.stockedGold,
                               title: "Cleared concurrency warnings",
                               detail: "Resolved a batch of Swift 6 actor-isolation warnings and one build error in the Siri shortcut, with no change to how the app behaves."),
            ]),
        // ── 1.10 (build 3) — guest data wipe fix ──────────────────────────────
        ChangelogVersion(
            version: "1.10",
            buildDate: "Build 3 · June 29, 2026 at 9:30 PM",
            headline: "Clearing data now really clears it",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "trash.fill", color: Color.stockedGold,
                               title: "Guest data clears completely",
                               detail: "In guest mode, clearing app data was leaving your inventory behind because of iCloud sync. Guests no longer use iCloud sync, so clearing now wipes everything as expected."),
            ]),
        // ── 1.9 (build 3) — inventory dark mode fix ───────────────────────────
        ChangelogVersion(
            version: "1.9",
            buildDate: "Build 3 · June 29, 2026 at 8:45 PM",
            headline: "Dark mode fix on Inventory",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "moon.fill", color: Color.stockedGold,
                               title: "Inventory cards match dark mode",
                               detail: "The status card and category tiles on the Inventory tab were showing a light background in dark mode. They now use the correct dark surface."),
            ]),
        // ── 1.8 (build 3) — recipe quality flag ───────────────────────────────
        ChangelogVersion(
            version: "1.8",
            buildDate: "Build 3 · June 29, 2026 at 8:00 PM",
            headline: "Spot incomplete recipes",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "exclamationmark.triangle.fill", color: Color.stockedGold,
                               title: "A heads-up on thin recipes",
                               detail: "Recipes that are missing key details, like steps or an image, now show a small Needs review tag so you know to double-check them before cooking."),
            ]),
        // ── 1.7 (build 3) — remember name corrections ─────────────────────────
        ChangelogVersion(
            version: "1.7",
            buildDate: "Build 3 · June 29, 2026 at 7:15 PM",
            headline: "Stocked learns your corrections",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "pencil.and.outline", color: Color.stockedGold,
                               title: "Fix a scanned name once",
                               detail: "When you correct a product name after scanning a barcode, Stocked remembers it, so the same product comes up with your name next time."),
            ]),
        // ── 1.6 (build 3) — usage insights wiring ─────────────────────────────
        ChangelogVersion(
            version: "1.6",
            buildDate: "Build 3 · June 29, 2026 at 6:30 PM",
            headline: "Better usage insights",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "chart.bar.fill", color: Color.stockedGold,
                               title: "The app understands your habits",
                               detail: "Stocked now privately tracks key actions on your device, like adding items, saving recipes, and finishing a cook, so your insights and streaks stay accurate. Nothing leaves your phone."),
            ]),
        // ── 1.5.1 (build 3) — reliability foundations ─────────────────────────
        ChangelogVersion(
            version: "1.5.1",
            buildDate: "Build 3 · June 29, 2026 at 5:45 PM",
            headline: "Under-the-hood reliability work",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.shield.fill", color: Color.stockedGold,
                               title: "Your data is safer across updates",
                               detail: "Added tests that make sure your saved kitchen keeps loading correctly when the app updates, so nothing gets lost."),
                ChangelogEntry(icon: "wand.and.stars", color: Color.stockedInfo,
                               title: "Groundwork for smarter suggestions",
                               detail: "New behind-the-scenes tools let the app rate recipe quality and remember your corrections, so suggestions keep improving over time."),
            ]),
        // ── 1.4 (build 2) — source quality + matching foundation ──────────────
        ChangelogVersion(
            version: "1.4",
            buildDate: "Build 2 · June 29, 2026 at 4:00 PM",
            headline: "Smarter about your groceries",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.triangle.merge", color: Color.stockedGold,
                               title: "Fewer duplicate ingredients",
                               detail: "The app now knows that ground beef, beef mince, and 80/20 beef are the same thing, so they no longer show up as separate grocery lines."),
                ChangelogEntry(icon: "wifi.slash", color: Color.stockedInfo,
                               title: "Works better offline",
                               detail: "Common grocery items are now recognized on device, so adding everyday items is faster and uses less data."),
            ]),
        // ── 1.3 — premium profile card ────────────────────────────────────────
        ChangelogVersion(
            version: "1.3",
            buildDate: "Build 1 · June 29, 2026 at 2:45 PM",
            headline: "A nicer profile in the menu",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "person.crop.circle.fill", color: Color.stockedGold,
                               title: "Refreshed profile card",
                               detail: "The side menu now shows your profile in a clean card with your account status and cook streak at a glance."),
            ]),
        // ── 1.2 — consistency + reliability ───────────────────────────────────
        ChangelogVersion(
            version: "1.2",
            buildDate: "Build 1 · June 29, 2026 at 1:30 PM",
            headline: "More consistent counts, fewer duplicates",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "calendar.badge.clock", color: Color.stockedGold,
                               title: "Expiring dates agree everywhere",
                               detail: "Home, Inventory, and Cook now use the exact same rule for what counts as expiring soon, so the numbers match across the app."),
                ChangelogEntry(icon: "cart.badge.plus", color: Color.stockedInfo,
                               title: "Fewer duplicate grocery items",
                               detail: "Adding something already on your list no longer creates a duplicate, no matter which screen you add it from."),
            ]),
        // ── 1.1 — dark mode contrast ──────────────────────────────────────────
        ChangelogVersion(
            version: "1.1",
            buildDate: "Build 1 · June 29, 2026 at 9:00 AM",
            headline: "Easier on the eyes in dark mode",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "moon.stars.fill", color: Color.stockedGold,
                               title: "Better dark mode contrast",
                               detail: "Gold accents are brighter and easier to read on dark backgrounds, and secondary text is clearer in both light and dark mode."),
            ]),
        // ── 07.42 — Build 301 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.42",
            buildDate: "Build 301 · June 2026",
            headline: "Guided tours everywhere",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Tours for every tab",
                               detail: "The guided tour now covers Inventory, Recipes, and Grocery too, so the first time you open each tab its main features are highlighted for you."),
                ChangelogEntry(icon: "doc.text.image", color: Color.stockedInfo,
                               title: "Find your Daily Brief",
                               detail: "The Home tour now shows you that tapping the Stocked title opens your full Daily Brief any time."),
            ]),
        // ── 07.41 — Build 300 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.41",
            buildDate: "Build 300 · June 2026",
            headline: "Cook tour, cleaner first run",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "frying.pan", color: Color.stockedGold,
                               title: "A tour for the Cook tab",
                               detail: "The first time you open Cook, a short tour highlights Cook Now and Cook Later so you know where to start."),
                ChangelogEntry(icon: "hand.wave", color: Color.stockedInfo,
                               title: "Smoother first launch",
                               detail: "Removed the old full-screen welcome carousel. New users are now introduced page by page, in place, as they explore."),
            ]),
        // ── 07.40 — Build 299 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.40",
            buildDate: "Build 299 · June 2026",
            headline: "A nicer guided tour",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Polished the tour glow",
                               detail: "The guided tour now has a softer, brighter glow around each feature, and the tip cards no longer cover the thing they are pointing at."),
            ]),
        // ── 07.39 — Build 298 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.39",
            buildDate: "Build 298 · June 2026",
            headline: "A guided tour of your kitchen",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Find your way around",
                               detail: "The first time you visit a page, a short guided tour now highlights the main features with a gentle glow, so nothing important gets missed. It starts with the Home screen."),
            ]),
        // ── 07.38 — Build 297 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.38",
            buildDate: "Build 297 · June 2026",
            headline: "Better support for larger text",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "textformat.size", color: Color.stockedInfo,
                               title: "Larger text sizes",
                               detail: "The app now supports larger system text sizes for better readability. Set your preferred size in iOS Settings under Display and Text Size."),
            ]),
        // ── 07.37 — Build 296 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.37",
            buildDate: "Build 296 · June 2026",
            headline: "Simpler profile and settings",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "person.crop.circle.fill", color: Color.stockedGold,
                               title: "A dedicated Edit Profile screen",
                               detail: "Tap your chef avatar in the menu to open Edit Profile, where you can change your avatar, your name, and all of your setup answers in one place. Updating your answers re-tunes your suggestions right away."),
                ChangelogEntry(icon: "slider.horizontal.3", color: Color.stockedInfo,
                               title: "Settings, right in the menu",
                               detail: "Preferences, Notifications, and Data & Storage now live as tap-to-expand sections directly in the side menu under Settings, so you no longer open a separate page to reach them."),
            ]),
        // ── 07.36 — Build 295 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.36",
            buildDate: "Build 295 · June 2026",
            headline: "Make your chef your own",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "person.crop.circle.badge.plus", color: Color.stockedGold,
                               title: "Personalize your chef",
                               detail: "You can now give your chef a different skin tone or use your own photo. Tap your chef avatar to choose."),
            ]),
        // ── 07.35 — Build 294 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.35",
            buildDate: "Build 294 · June 2026",
            headline: "Build fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "wrench.and.screwdriver.fill", color: Color.stockedCharcoal,
                               title: "Compile fix",
                               detail: "A small internal fix so the app builds cleanly. No visible changes."),
            ]),
        // ── 07.34 — Build 293 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.34",
            buildDate: "Build 293 · June 2026",
            headline: "Under-the-hood tidy-up",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedInfo,
                               title: "Cleaner, leaner code",
                               detail: "Removed unused screens and pulled repeated bits of code together behind the scenes. No visible changes — just a tidier app that is easier to keep consistent going forward."),
            ]),
        // ── 07.33 — Build 292 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.33",
            buildDate: "Build 292 · June 2026",
            headline: "Consistent expiring-soon window",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "calendar.badge.exclamationmark", color: Color.stockedError,
                               title: "Expiring soon, everywhere the same",
                               detail: "The Use It Soon widget and the full Expiring Soon list now use the same window — items expiring within four days — so they always agree on what counts as expiring soon."),
            ]),
        // ── 07.32 — Build 291 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.32",
            buildDate: "Build 291 · June 2026",
            headline: "Fresh meal-prep ideas every time",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGreen,
                               title: "Quick Picks refresh",
                               detail: "The Quick Picks on the Meal Prep screen now pull a fresh, shuffled set of ideas from the recipe library each time you open the screen, instead of always showing the same eight."),
            ]),
        // ── 07.31 — Build 290 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.31",
            buildDate: "Build 290 · June 2026",
            headline: "Behind-the-scenes fixes",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "stethoscope", color: Color.stockedInfo,
                               title: "Chasing down a glitch",
                               detail: "Added some behind-the-scenes diagnostics to track down a reported issue with the Use It Soon list. No visible changes — this just helps us pinpoint and fix it."),
            ]),
        // ── 07.30 — Build 289 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.30",
            buildDate: "Build 289 · June 2026",
            headline: "Preferences, all on one page",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "slider.horizontal.3", color: Color.stockedInfo,
                               title: "One tidy Preferences page",
                               detail: "Everything now lives on a single Preferences page with four tap-to-expand sections: Edit Profile, Preferences, Notifications, and Data & Storage. No more hunting through separate menus."),
                ChangelogEntry(icon: "person.crop.circle.fill", color: Color.stockedGold,
                               title: "Edit Profile in one place",
                               detail: "Edit your name and retake the setup questions from the Edit Profile section. Retaking the questions updates your suggestions to match."),
                ChangelogEntry(icon: "rectangle.3.group.fill", color: .orange,
                               title: "Less clutter",
                               detail: "Settings that used to appear in more than one spot now appear exactly once, each tucked into the section it belongs to."),
            ]),
        // ── 07.29 — Build 288 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.29",
            buildDate: "Build 288 · June 2026",
            headline: "Polish: cleaner header, smoother sign-in",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "textformat", color: Color.stockedCharcoal,
                               title: "A cleaner wordmark",
                               detail: "The period after the Stocked name now matches the rest of the title instead of standing out in gold, for a calmer, more polished header on every screen."),
                ChangelogEntry(icon: "rectangle.portrait.and.arrow.right", color: .orange,
                               title: "Exit guest mode takes you home",
                               detail: "When you leave guest mode — whether you keep your data or clear it — you are now taken straight back to the sign-in screen, instead of being left inside the app."),
                ChangelogEntry(icon: "person.crop.circle.badge.checkmark", color: Color.stockedGold,
                               title: "Your name sticks with Apple sign-in",
                               detail: "If you sign in with your Apple ID, the app now remembers your first name for your greeting, so it stays personal every time you come back — not just the first time."),
            ]),
        // ── 07.28 — Build 287 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.28",
            buildDate: "Build 287 · June 2026",
            headline: "Everything in one place",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "person.crop.circle.fill", color: Color.stockedGold,
                               title: "A cleaner profile screen",
                               detail: "Your profile now shows every setting and preference on one screen, neatly grouped into categories like Account, Appearance, Notifications, and Backup, with no more digging through sub-menus."),
                ChangelogEntry(icon: "checklist", color: .orange,
                               title: "Adjust onboarding",
                               detail: "The old Edit Profile option is now called Adjust onboarding, so it is clearer that it re-opens the dietary, skill, and cuisine questions."),
            ]),
        // ── 07.27 — Build 286 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.27",
            buildDate: "Build 286 · June 2026",
            headline: "Swipe to open the menu",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.draw.fill", color: Color.stockedGold,
                               title: "Drag the menu open",
                               detail: "You can now slide the side menu open with a swipe from the left edge, and push it closed with a swipe back. Tapping the edge handle still works too."),
            ]),
        // ── 07.26 — Build 285 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.26",
            buildDate: "Build 285 · June 2026",
            headline: "Reminders that actually reach you",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "bell.badge.fill", color: Color.stockedGold,
                               title: "Reminders now arrive outside the app",
                               detail: "Expiry, cook, low-staple and meal-prep reminders are no longer cleared in the background, so they show up on your Lock Screen even when Stocked is closed."),
                ChangelogEntry(icon: "clock.fill", color: Color.stockedGold,
                               title: "Choose when each reminder arrives",
                               detail: "Every reminder type now has its own time picker in Notification settings, so you decide exactly when each one is delivered."),
                ChangelogEntry(icon: "checkmark.shield.fill", color: Color.stockedGreen,
                               title: "See if notifications are allowed",
                               detail: "Notification settings now show whether the system has notifications turned on, with a quick shortcut to fix it if they are switched off."),
            ]),
        // ── 07.25 — Build 284 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.25",
            buildDate: "Build 284 · June 2026",
            headline: "A warmer welcome",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.wave.fill", color: Color.stockedGold,
                               title: "New welcome tour",
                               detail: "First-time users now get a quick, swipeable intro to the app — including a heads-up about the menu hidden along the left edge, where scanning, adding, and search live."),
            ]),
        // ── 07.24 — Build 283 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.24",
            buildDate: "Build 283 · June 2026",
            headline: "A new way to Cook",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "fork.knife", color: Color.stockedGold,
                               title: "Reimagined Cook tab",
                               detail: "Cook now starts with a simple choice — cook tonight or plan ahead. Cook Now helps you build around what you have, match your mood, or get a surprise pick, with smart insights about what's ready to make."),
                ChangelogEntry(icon: "calendar", color: Color.stockedGold,
                               title: "Cook Later planning",
                               detail: "Plan meals across the week and get a prep checklist, with your upcoming plans right on the Cook Later home."),
            ]),
        // ── 07.23 — Build 282 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.23",
            buildDate: "Build 282 · June 2026",
            headline: "Household sharing",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "person.2.fill", color: Color.stockedGold,
                               title: "Share your kitchen",
                               detail: "Create a household and invite family with a simple code. They can see your pantry and add to a shared grocery list."),
                ChangelogEntry(icon: "checklist", color: Color.stockedGreen,
                               title: "Collaborative grocery list",
                               detail: "Household members can add items and check them off together — and every item shows who added it."),
                ChangelogEntry(icon: "clock.arrow.circlepath", color: Color.stockedInfo,
                               title: "Household activity feed",
                               detail: "See everything happening in your household — who added what, and when.")
            ]
        ),
        // ── 07.22 — Build 281 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.22",
            buildDate: "Build 281 · June 2026",
            headline: "A cleaner, easier-to-read grocery list",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "cart", color: Color.stockedGold,
                               title: "Tidier empty grocery list",
                               detail: "When your list is empty but items are running low, you'll see a compact prompt with your restock suggestions front and center, instead of a big empty screen."),
                ChangelogEntry(icon: "eye", color: Color.stockedGreen,
                               title: "Easier-to-read low-stock labels",
                               detail: "The percent-left text on running-low items is now high-contrast and easy to read, with red reserved for items you're completely out of.")
            ]
        ),
        // ── 07.21 — Build 280 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.21",
            buildDate: "Build 280 · June 2026",
            headline: "Premium unlock, privacy, and reliability",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "creditcard", color: Color.stockedGold,
                               title: "Real Household Sync purchase",
                               detail: "The Household Sync unlock now uses the App Store with proper purchase and restore — the owner buys once and the household is covered."),
                ChangelogEntry(icon: "hand.raised", color: Color.stockedGreen,
                               title: "Privacy & diagnostics",
                               detail: "Added a privacy manifest and on-device crash/hang diagnostics, so the app is App Store-ready and easier to keep stable."),
                ChangelogEntry(icon: "mic", color: Color.stockedInfo,
                               title: "Ask Siri what's expiring",
                               detail: "A new shortcut answers \"What's expiring in Stocked?\" out loud."),
                ChangelogEntry(icon: "cart.badge.minus", color: Color.stockedGold,
                               title: "No more duplicate grocery lines",
                               detail: "Adding items now ignores accents and capitalization, so \"milk\" and \"Milk\" won't double up.")
            ]
        ),
        // ── 07.18 — Build 277 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.18",
            buildDate: "Build 277 · June 2026",
            headline: "Get started faster, smarter reminders, home-screen widgets",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Guided first setup",
                               detail: "An empty kitchen now shows a quick start card — stock common staples or scan a receipt in one tap, so Stocked has something to work with right away."),
                ChangelogEntry(icon: "bell.badge", color: Color.stockedInfo,
                               title: "Act on reminders instantly",
                               detail: "Expiry reminders now have Add to Grocery and Mark Used buttons, and tapping one opens that exact item."),
                ChangelogEntry(icon: "square.text.square", color: Color.stockedGreen,
                               title: "Home & Lock Screen widgets",
                               detail: "New widgets show what's expiring, what you can cook today, and your grocery count at a glance."),
                ChangelogEntry(icon: "magnifyingglass", color: Color.stockedGold,
                               title: "Accent-friendly search",
                               detail: "Search now ignores accents and case, so \"jalapeno\" finds \"jalapeño\".")
            ]
        ),
        // ── 07.17 — Build 276 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.17",
            buildDate: "Build 276 · June 2026",
            headline: "Familiar tab icons",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.grid.2x2", color: Color.stockedGold,
                               title: "Cleaner tab icons",
                               detail: "Home, Inventory, Recipes, and Grocery use clean system icons; the Cook tab keeps its chef's hat. All five stay matched in size and alignment.")
            ]
        ),
        // ── 07.16 — Build 275 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.16",
            buildDate: "Build 275 · June 2026",
            headline: "Smarter scans, offline-aware, faster recipes",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "plusminus", color: Color.stockedGold,
                               title: "Fix scanned quantities",
                               detail: "When reviewing a scanned receipt you can bump an item's count up or down right in the list."),
                ChangelogEntry(icon: "wifi.slash", color: Color.stockedInfo,
                               title: "Offline awareness",
                               detail: "Stocked shows a small offline badge so you know changes are saved on-device and will sync when you reconnect."),
                ChangelogEntry(icon: "gauge.with.dots.needle.33percent", color: Color.stockedGreen,
                               title: "Recipe sync stays in budget",
                               detail: "Background recipe updates track a safe daily limit, so the recipe service never runs out partway through the day.")
            ]
        ),
        // ── 07.15 — Build 274 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.15",
            buildDate: "Build 274 · June 2026",
            headline: "Even tab icons",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.grid.2x2", color: Color.stockedGold,
                               title: "Matched icon sizes",
                               detail: "All five tab icons are scaled and centered to the same size.")
            ]
        ),
        // ── 07.14 — Build 273 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.14",
            buildDate: "Build 273 · June 2026",
            headline: "Cleaner Preferences",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "list.bullet", color: Color.stockedInfo,
                               title: "Simpler Preferences",
                               detail: "Settings are one straightforward list grouped under headers. Preferred Store moved under Account."),
                ChangelogEntry(icon: "calendar", color: Color.stockedGold,
                               title: "Plan from Inventory",
                               detail: "The drag-to-plan week strip now appears on the main Inventory screen too.")
            ]
        ),
        // ── 07.13 — Build 272 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.13",
            buildDate: "Build 272 · June 2026",
            headline: "Tab bar matches the design",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "dock.rectangle", color: Color.stockedGold,
                               title: "Flat tab bar",
                               detail: "The bottom tab bar now sits flat on the background like the mockup, instead of a dark floating pill. The active tab is gold.")
            ]
        ),
        // ── 07.12 — Build 271 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.12",
            buildDate: "Build 271 · June 2026",
            headline: "Tab bar always visible",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "dock.rectangle", color: Color.stockedGold,
                               title: "Bottom bar stays put",
                               detail: "The tab bar no longer hides when you scroll — Home, Cook, Inventory, Recipes, and Grocery List are visible on every screen.")
            ]
        ),
        // ── 07.11 — Build 270 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.11",
            buildDate: "Build 270 · June 2026",
            headline: "Reverted the tab walkthrough",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.uturn.backward", color: Color.stockedGold,
                               title: "Walkthrough restored",
                               detail: "Put the first-run tab tour back to the way it was in 07.9. All the other recent fixes are unchanged.")
            ]
        ),
        // ── 07.10 — Build 269 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "07.10",
            buildDate: "Build 269 · June 2026",
            headline: "Scanning, sliders, and onboarding polish",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "slider.horizontal.below.rectangle", color: Color.stockedGold,
                               title: "Tap a level bar to set it",
                               detail: "You can now tap anywhere on an item's level bar to set it, not just drag."),
                ChangelogEntry(icon: "tray.full.fill", color: Color.stockedGreen,
                               title: "Smarter zone for new items",
                               detail: "New items pick their zone from what you're adding — seasonings and spices now default to Staples — instead of sticking to the last area."),
                ChangelogEntry(icon: "cart.fill", color: Color.stockedInfo,
                               title: "H-E-B receipt support",
                               detail: "H-E-B is recognized when scanning receipts, with HEB store brands (Hill Country Fare, Central Market, Creamy Creations, Meal Simple) added."),
                ChangelogEntry(icon: "hand.tap.fill", color: Color.stockedGold,
                               title: "Clearer first-run tour",
                               detail: "The walkthrough now includes the Cook tab and points at the right tabs, and its overlay is lighter so you can see the screen behind it.")
            ]
        ),
        // ── 07.9 — Build 268 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "07.9",
            buildDate: "Build 268 · June 2026",
            headline: "A batch of polish and fixes",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "person.crop.circle.fill", color: Color.stockedGold,
                               title: "Your chef icon moved to the menu",
                               detail: "Your profile and preferences now live in the side menu, right under Stocked, with the chef icon you picked during setup."),
                ChangelogEntry(icon: "checkmark.circle.fill", color: Color.stockedGreen,
                               title: "Finishing setup opens Home",
                               detail: "Completing the personality quiz now reliably takes you to your home screen instead of a blank screen."),
                ChangelogEntry(icon: "rectangle.grid.1x2.fill", color: Color.stockedInfo,
                               title: "Smoother widget editing",
                               detail: "Rearranging home widgets no longer leaves cards greyed out, and the home prompt now explains press-and-hold to rearrange."),
                ChangelogEntry(icon: "textformat.alt", color: Color.stockedGold,
                               title: "Centered headers & friendlier greeting",
                               detail: "Screen headers are centered, the splash wordmark's period is black, and the greeting uses your first name.")
            ]
        ),
        // ── 07.8 — Build 267 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "07.8",
            buildDate: "Build 267 · June 2026",
            headline: "Categories works, cuisine list tidied",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.grid.2x2.fill", color: Color.stockedGold,
                               title: "Tapping Categories opens the right screen",
                               detail: "A tap on Categories was being captured by the Discover card behind it. Now it reliably opens the cuisine browser."),
                ChangelogEntry(icon: "flag.fill", color: Color.stockedGreen,
                               title: "Only real cuisines listed",
                               detail: "The cuisine list now shows only recognized cuisines with a flag, dropping unlabeled or empty entries.")
            ]
        ),
        // ── 07.7 — Build 266 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "07.7",
            buildDate: "Build 266 · June 2026",
            headline: "Categories opens the right screen",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.grid.2x2.fill", color: Color.stockedGold,
                               title: "Tapping Categories works",
                               detail: "The Categories card now reliably opens the cuisine list instead of opening a recipe. The other hub cards are more reliable too.")
            ]
        ),
        // ── 07.3 — Build 258 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "07.3",
            buildDate: "Build 258 · June 2026",
            headline: "Categories, now a card",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.grid.2x2.fill", color: Color.stockedGold,
                               title: "Browse cuisines from its own card",
                               detail: "Categories moved into its own card alongside Favorites, Cooked, Saved, and Collections — tap it to browse recipes by cuisine like Italian, Mexican, or American."),
                ChangelogEntry(icon: "checkmark.circle.fill", color: Color.stockedGreen,
                               title: "Fixed an opening bug",
                               detail: "Tapping the old Categories link could open a recipe instead of the cuisine list. That's resolved.")
            ]
        ),
        // ── 07.2 — Build 257 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "07.2",
            buildDate: "Build 257 · June 2026",
            headline: "Browse by category, a tidier layout",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.grid.2x2.fill", color: Color.stockedGold,
                               title: "Browse recipes by category",
                               detail: "The Discover row now has a Categories button — tap it to browse recipes by cuisine like Italian, Mexican, or American, each opening real recipes with full instructions."),
                ChangelogEntry(icon: "arrow.up.to.line", color: Color.stockedGreen,
                               title: "A tidier top",
                               detail: "The empty band at the top of every screen is gone, so pages start higher and make better use of the space."),
                ChangelogEntry(icon: "barcode.viewfinder", color: Color.stockedInfo,
                               title: "Full-size barcode scanner",
                               detail: "The barcode scanner now opens full-size, the same way the receipt scanner does.")
            ]
        ),
        // ── 07.1 — Build 256 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "07.1",
            buildDate: "Build 256 · June 2026",
            headline: "More recipe sources, cleaner results",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.stack.3d.up.fill", color: Color.stockedGold,
                               title: "Discover pulls from more sources",
                               detail: "Beyond TheMealDB, Discover now blends in TheCocktailDB drinks and full Spoonacular recipes — with Tasty available too — for a wider, fresher mix."),
                ChangelogEntry(icon: "list.bullet.rectangle.fill", color: Color.stockedGreen,
                               title: "Every recipe has real steps",
                               detail: "Recipes without step-by-step instructions — or whose instructions were just a link — are no longer shown, so what you see is always cookable."),
                ChangelogEntry(icon: "rectangle.on.rectangle.slash", color: Color.stockedInfo,
                               title: "No more duplicates",
                               detail: "When the same dish comes back from more than one source, it's merged so it only appears once."),
                ChangelogEntry(icon: "link.circle.fill", color: Color.stockedGold,
                               title: "Import by URL, fixed",
                               detail: "The drawer's Import Recipe now opens the URL importer directly, and importing a link no longer loops.")
            ]
        ),
        // ── 0.7.0 — Build 255 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.7.0",
            buildDate: "Build 255 · June 2026",
            headline: "Numbers you can trust, a Home you can arrange",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "equal.circle.fill", color: Color.stockedGreen,
                               title: "Consistent counts everywhere",
                               detail: "Meals ready, % stocked, expiring, and low-stock now match across Home, the Daily Brief, and your kitchen — one source of truth."),
                ChangelogEntry(icon: "arrow.up.arrow.down", color: Color.stockedGold,
                               title: "Rearrange your widgets",
                               detail: "Touch and hold Home, then drag any widget to reorder it — alongside adding and removing from the gallery."),
                ChangelogEntry(icon: "frying.pan.fill", color: Color.stockedGold,
                               title: "Cook Right Now",
                               detail: "A new screen shows only what you can make tonight, putting the ingredients that are about to expire first."),
                ChangelogEntry(icon: "bell.badge.fill", color: Color.stockedInfo,
                               title: "Reminders that suggest a meal",
                               detail: "When food is about to expire, Stocked can nudge you with a recipe that uses it up — and tapping a reminder now takes you straight there."),
                ChangelogEntry(icon: "chart.pie.fill", color: Color.stockedGreen,
                               title: "Private usage insights",
                               detail: "A new on-device view shows which features you use most. It's local-only — nothing is ever uploaded.")
            ]
        ),
        // ── 0.6.9 — Build 254 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.6.9",
            buildDate: "Build 254 · June 2026",
            headline: "Tab bar's back, Cook Later gets photos",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "rectangle.bottombar.fill", color: Color.stockedGold,
                               title: "The floating tab bar returns",
                               detail: "Back to the rounded charcoal pill that tucks away as you scroll and slides up with a tap near the bottom — just like before."),
                ChangelogEntry(icon: "photo.fill", color: Color.stockedGreen,
                               title: "Cook Later, in full color",
                               detail: "Meals in the Cook Later area now show the recipe photo across the whole card, with the title right on the image.")
            ]
        ),
        // ── 0.6.8 — Build 253 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.6.8",
            buildDate: "Build 253 · June 2026",
            headline: "Twenty-plus widgets for your Home",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.grid.3x3.fill", color: Color.stockedGold,
                               title: "A bigger widget gallery",
                               detail: "Build your Home from 20+ widgets — stock level, meals ready, your cooking streak, shopping list, expiring items, quick shortcuts to Cook, Discover, scanning, and more."),
                ChangelogEntry(icon: "slider.horizontal.3", color: Color.stockedGreen,
                               title: "Daily Brief, your call",
                               detail: "The Daily Brief is no longer fixed on Home — it's now an optional widget you can add or remove like any other."),
                ChangelogEntry(icon: "leaf.fill", color: Color.stockedInfo,
                               title: "More than numbers",
                               detail: "New Ready to Cook, Waste Tracker, Preferred Store, and Kitchen Tip widgets bring useful detail right to your Home screen.")
            ]
        ),
        // ── 0.6.7 — Build 252 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.6.7",
            buildDate: "Build 252 · June 2026",
            headline: "Make Home yours",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.tap.fill", color: Color.stockedGold,
                               title: "Touch and hold to customize",
                               detail: "Press and hold anywhere on Home and the widgets start to jiggle — just like rearranging apps on your iPhone."),
                ChangelogEntry(icon: "minus.circle.fill", color: Color.stockedError,
                               title: "Remove what you don't use",
                               detail: "Tap the − on any widget to take it off your Home screen. Your layout is remembered."),
                ChangelogEntry(icon: "plus.square.on.square", color: Color.stockedGreen,
                               title: "Add widgets back anytime",
                               detail: "Changed your mind? The Add Widgets gallery lets you put the Daily Brief, What's New, Action Center, or Use It Soon back whenever you like.")
            ]
        ),
        // ── 0.6.6 — Build 251 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.6.6",
            buildDate: "Build 251 · June 2026",
            headline: "Smarter recipes, a kitchen that starts itself",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.circle.fill", color: Color.stockedGreen,
                               title: "\"Can I make this?\" everywhere",
                               detail: "Every online recipe now shows whether you can cook it right now or how many ingredients you're missing — checked live against your kitchen."),
                ChangelogEntry(icon: "wand.and.stars", color: Color.stockedGold,
                               title: "A kitchen that starts itself",
                               detail: "New here? One tap stocks 15 common staples so Cook and Discover light up with meals immediately — or add items by hand."),
                ChangelogEntry(icon: "bookmark.fill", color: Color.stockedInfo,
                               title: "Saved, sorted, and safer",
                               detail: "Recipes you've saved are marked so you don't re-add them, Discover learns what you open, and recipes flag your allergens — with a Hide allergens toggle when browsing."),
                ChangelogEntry(icon: "arrow.uturn.backward.circle.fill", color: Color.stockedGreen,
                               title: "Undo a delete",
                               detail: "Removed an item by mistake? Tap Undo. And your makeable-meals count now matches across Home, the Daily Brief, and the Kitchen Report.")
            ]
        ),
        // ── 0.6.5 — Build 250 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.6.5",
            buildDate: "Build 250 · June 2026",
            headline: "Collapse the brief, scan a barcode",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "chevron.up.chevron.down", color: Color.stockedGold,
                               title: "Collapsible Daily Brief",
                               detail: "Tap the chevron to fold the Daily Brief down to its title and clear room on your Home screen — it remembers how you left it."),
                ChangelogEntry(icon: "barcode.viewfinder", color: Color.stockedGreen,
                               title: "Scan a barcode",
                               detail: "A new Scan Barcode action joins the Action Center, and there's now a Scan button right on the Add Item screen — point at a product and it's looked up and added for you."),
                ChangelogEntry(icon: "square.grid.2x2.fill", color: Color.stockedInfo,
                               title: "Roomier Action Center",
                               detail: "The quick actions now sit in a tidy 2×2 grid to fit the new option.")
            ]
        ),
        // ── 0.6.4 — Build 249 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.6.4",
            buildDate: "Build 249 · June 2026",
            headline: "A tab bar that stays put",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "dock.rectangle", color: Color.stockedGold,
                               title: "Always-on navigation",
                               detail: "The bottom bar no longer slides away when you scroll — Home, Cook, Inventory, Recipes, and Grocery List are always one tap away."),
                ChangelogEntry(icon: "paintbrush.fill", color: Color.stockedGreen,
                               title: "Cleaner look",
                               detail: "The bar now sits flush at the bottom with a light, simple style — the active tab glows gold so you always know where you are.")
            ]
        ),
        // ── 0.6.3 — Build 248 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.6.3",
            buildDate: "Build 248 · June 2026",
            headline: "Discover recipes from the web",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "globe", color: Color.stockedGold,
                               title: "A new Discover section",
                               detail: "The Recipes tab now fills up with real recipes from online sources — a big featured pick, plus rails for what's popular, dinner ideas, and something sweet."),
                ChangelogEntry(icon: "hand.tap.fill", color: Color.stockedGreen,
                               title: "Tap to explore",
                               detail: "Open any card for the full recipe — save it to your collection or send its ingredients to your grocery list in one tap."),
                ChangelogEntry(icon: "magnifyingglass.circle.fill", color: Color.stockedInfo,
                               title: "See All opens the browser",
                               detail: "Want more? See All opens the full recipe browser with search and cuisine filters.")
            ]
        ),
        // ── 0.6.2 — Build 247 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.6.2",
            buildDate: "Build 247 · June 2026",
            headline: "The Cook tab comes alive",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "frying.pan.fill", color: Color.stockedGold,
                               title: "14 starter meals built in",
                               detail: "Everyday favorites like Garlic Butter Chicken, Beef Tacos, and Veggie Stir Fry now live in the app — so Cook Now and Cook Later fill up the moment your kitchen has ingredients, even before you've saved a single recipe."),
                ChangelogEntry(icon: "checklist", color: Color.stockedGreen,
                               title: "Honest missing counts",
                               detail: "Every '1 missing' or '2 missing' badge is checked live against what's actually in your kitchen — and tapping a meal shows the full recipe with steps."),
                ChangelogEntry(icon: "equal.circle.fill", color: Color.stockedInfo,
                               title: "Numbers that agree",
                               detail: "The makeable-meals count on Home and in your Daily Brief now matches exactly what the Cook Now rail shows.")
            ]
        ),
        // ── 0.6.1 — Build 246 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.6.1",
            buildDate: "Build 246 · June 2026",
            headline: "The full redesign",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "A new Home",
                               detail: "Your Daily Brief is now a beautiful dark card up top, with What's New activity, a quick Action Center, and Use It Soon all on one screen."),
                ChangelogEntry(icon: "frying.pan.fill", color: Color.stockedCharcoal,
                               title: "Cook, simplified",
                               detail: "Two big choices — Cook Now or Cook Later — plus a photo rail of meals you can make and a list of dishes that are just a few ingredients away."),
                ChangelogEntry(icon: "square.grid.2x2.fill", color: Color.stockedGreen,
                               title: "Inventory at a glance",
                               detail: "The Pantry tab opens to a dashboard: how stocked you are, six tidy categories, and what's expiring soon — with the full list one tap away."),
                ChangelogEntry(icon: "textformat", color: Color.stockedInfo,
                               title: "Polished everywhere",
                               detail: "Every tab gets its own elegant header, the expanded Daily Brief got a richer layout, the side drawer was reorganized, and the tab bar has a fresh new shape.")
            ]
        ),
        // ── 0.6.0 — Build 245 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.6.0",
            buildDate: "Build 245 · June 2026",
            headline: "Audited against the design",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal.fill", color: Color.stockedGreen,
                               title: "Every tab, conformed",
                               detail: "Inventory, Recipes, Grocery, the Daily Brief, the Kitchen Report, and the drawer now match the design exactly — nothing extra, nothing missing."),
                ChangelogEntry(icon: "square.grid.2x2.fill", color: Color.stockedGold,
                               title: "Recipes hub goes live",
                               detail: "Favorites, Cooked, Saved, and Collections now open real screens, and Top Categories takes you straight to each cuisine."),
                ChangelogEntry(icon: "slider.horizontal.3", color: Color.stockedInfo,
                               title: "Cleaner chrome",
                               detail: "Search appears on demand, sort lives in a tidy pill, and grocery extras moved into the ··· menu — with Help Center and Log Out now one tap away in the drawer.")
            ]
        ),
        // ── 0.5.9 — Build 244 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.5.9",
            buildDate: "Build 244 · June 2026",
            headline: "The full design, 1:1",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "house.fill", color: Color.stockedGold,
                               title: "Home, to the letter",
                               detail: "Quick Actions, Kitchen Overview, See Daily Brief, Continue Cooking, Use Tonight, and Household Activity — in exactly the designed order."),
                ChangelogEntry(icon: "rectangle.split.2x1.fill", color: Color.stockedInfo,
                               title: "Daily Brief, redesigned",
                               detail: "Pull down from Stocked. for the new two-column brief: your stats on the left, At a Glance on the right."),
                ChangelogEntry(icon: "folder.fill", color: Color.stockedGreen,
                               title: "Top Categories & smarter grocery",
                               detail: "Recipes adds Top Categories; the grocery list now groups by store section — Produce, Bakery, Dairy, Meat, Frozen, Pantry.")
            ]
        ),
        // ── 0.5.8 — Build 243 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.5.8",
            buildDate: "Build 243 · June 2026",
            headline: "Home shows everything",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "house.fill", color: Color.stockedGold,
                               title: "Sections always visible",
                               detail: "What's New and Use It Soon now always appear on Home — with friendly placeholders when there's nothing yet, and live rows the moment there is.")
            ]
        ),
        // ── 0.5.7 — Build 242 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.5.7",
            buildDate: "Build 242 · June 2026",
            headline: "Home, exactly as designed",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "house.fill", color: Color.stockedGold,
                               title: "The new Home",
                               detail: "Your Daily Brief now lives right on Home as a dark card, followed by What's New, the Action Center, and Use It Soon — matched to the new design, piece for piece.")
            ]
        ),
        // ── 0.5.6 — Build 241 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.5.6",
            buildDate: "Build 241 · June 2026",
            headline: "Pixel-matched to the new design",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "refrigerator.fill", color: Color.stockedGold,
                               title: "Inventory, exactly right",
                               detail: "Zone cards, the stacked zone header, and clean item rows — emoji, name, quantity, and expiry — now match the new design precisely."),
                ChangelogEntry(icon: "frying.pan.fill", color: Color.stockedGreen,
                               title: "Cook cards reshaped",
                               detail: "Cook Now and Cook Later get the design's larger, rounder cards with bold icon circles.")
            ]
        ),
        // ── 0.5.5 — Build 240 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.5.5",
            buildDate: "Build 240 · June 2026",
            headline: "The last mockup pieces",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "clock.arrow.circlepath", color: Color.stockedGold,
                               title: "Recently Viewed",
                               detail: "Recipes you open now show up in a Recently Viewed row at the top of your Recipes tab — jump back in with one tap."),
                ChangelogEntry(icon: "person.2.fill", color: Color.stockedGreen,
                               title: "Household Activity, fleshed out",
                               detail: "Activity on Home now reads naturally — ‘you used Milk’, ‘you cooked Sticky Chicken’ — with a View All feed of everything added, used, and tossed."),
                ChangelogEntry(icon: "house.and.flag.fill", color: Color.stockedInfo,
                               title: "Household in the drawer",
                               detail: "Household Sync gets its own drawer section, one tap from anywhere.")
            ]
        ),
        // ── 0.5.4 — Build 239 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.5.4",
            buildDate: "Build 239 · June 2026",
            headline: "A tidier drawer",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sidebar.left", color: Color.stockedGold,
                               title: "Organized drawer",
                               detail: "The side drawer is now grouped into Kitchen Tools and Insights — with Quick Update right there alongside Scan Receipt, Add Item, and Global Search."),
                ChangelogEntry(icon: "sparkles", color: Color.stockedGreen,
                               title: "Redesign complete",
                               detail: "The new look has rolled out across the whole app: five tabs, dashboard Home, Cook tab, redesigned Inventory and Grocery, Recipes hub, Kitchen Report, dark Daily Brief, and this drawer.")
            ]
        ),
        // ── 0.5.3 — Build 238 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.5.3",
            buildDate: "Build 238 · June 2026",
            headline: "Kitchen Report & Recipes hub",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "chart.pie.fill", color: Color.stockedGreen,
                               title: "Full Kitchen Report",
                               detail: "Kitchen Stats opens with the new dark report: your health ring, per-zone breakdown bars, meal readiness, expirations, this week's activity, and shopping readiness."),
                ChangelogEntry(icon: "square.grid.2x2.fill", color: Color.stockedGold,
                               title: "Recipes hub",
                               detail: "Favorites, Cooked, Saved, and Collections at the top of your Recipes tab with live counts."),
                ChangelogEntry(icon: "moon.fill", color: Color.stockedInfo,
                               title: "Darker Daily Brief",
                               detail: "The Daily Brief gets the new dark look with an At a Glance row: expiring, to buy, meals available, and prep planned.")
            ]
        ),
        // ── 0.5.2 — Build 237 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.5.2",
            buildDate: "Build 237 · June 2026",
            headline: "Rows that match the new look",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "list.bullet.rectangle.fill", color: Color.stockedGold,
                               title: "Inventory rows redesigned",
                               detail: "Every item now shows a food emoji, a cleaner quantity line, and a clear orange expiry on the right — just like the new design."),
                ChangelogEntry(icon: "checkmark.square.fill", color: Color.stockedGreen,
                               title: "Grocery rows refreshed",
                               detail: "Square checkboxes and food emoji bring the grocery list in line with the rest of the redesign.")
            ]
        ),
        // ── 0.5.1 — Build 236 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.5.1",
            buildDate: "Build 236 · June 2026",
            headline: "Inventory & Grocery, redesigned",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "refrigerator.fill", color: Color.stockedGold,
                               title: "A cleaner Inventory",
                               detail: "Zone tabs with icons, a clear zone header with item counts, food emoji on every item, and friendlier expiry labels like ‘Expires tomorrow’."),
                ChangelogEntry(icon: "cart.fill", color: Color.stockedGreen,
                               title: "To Buy and Bought",
                               detail: "Your grocery list now splits into To Buy and Bought tabs, plus a new Add Item button that's always within reach.")
            ]
        ),
        // ── 0.5.0 — Build 235 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.5.0",
            buildDate: "Build 235 · June 2026",
            headline: "A whole new look",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "frying.pan.fill", color: Color.stockedGold,
                               title: "New Cook tab",
                               detail: "Cooking gets its own home: Cook Now and Cook Later, meals you can make with what you have, and your recent meals — all in one place."),
                ChangelogEntry(icon: "house.fill", color: Color.stockedGreen,
                               title: "Redesigned Home",
                               detail: "Your kitchen at a glance: quick actions, kitchen health with live stats, what to use tonight, your meal prep queue, and recent activity."),
                ChangelogEntry(icon: "rectangle.3.group.fill", color: Color.stockedInfo,
                               title: "Five tabs",
                               detail: "Home, Cook, Inventory, Recipes, and Grocery List — the layout from the new design, with more screens updating soon.")
            ]
        ),
        // ── 0.4.15 — Build 234 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "0.4.15",
            buildDate: "Build 234 · June 2026",
            headline: "Lock Screen timer looks right",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "timer", color: Color.stockedGold,
                               title: "One-line countdown",
                               detail: "The cooking timer on your Lock Screen and Dynamic Island now shows on a single clean line instead of wrapping.")
            ]
        ),
        // ── 0.4.14 — Build 233 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "0.4.14",
            buildDate: "Build 233 · June 2026",
            headline: "Timer troubleshooting",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "info.circle.fill", color: Color.stockedInfo,
                               title: "Timer confirmation",
                               detail: "When you start a step timer, the cook screen now confirms it was sent to the Lock Screen — making it obvious whether the timer feature is reaching the system.")
            ]
        ),
        // ── 0.4.13 — Build 232 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "0.4.13",
            buildDate: "Build 232 · June 2026",
            headline: "Cooking pill stays gone",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "flame.fill", color: Color.stockedGold,
                               title: "Pill clears for real",
                               detail: "Finishing a cook and backing out of the plating screen no longer brings the ‘Cooking’ pill back — once you're done, it's done."),
                ChangelogEntry(icon: "exclamationmark.triangle.fill", color: Color.stockedInfo,
                               title: "Clearer timer guidance",
                               detail: "If Lock Screen timers are switched off, the cook screen now tells you right away instead of staying silent.")
            ]
        ),
        // ── 0.4.12 — Build 231 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "0.4.12",
            buildDate: "Build 231 · June 2026",
            headline: "Finish Cooking fixed for good",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.circle.fill", color: Color.stockedGreen,
                               title: "No more blank screen",
                               detail: "Pressing Finish Cooking now always takes you to the plating screen — the blank-screen bug is gone, whether you started fresh or resumed from the pill.")
            ]
        ),
        // ── 0.4.11 — Build 230 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "0.4.11",
            buildDate: "Build 230 · June 2026",
            headline: "Finish Cooking fixed",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.circle.fill", color: Color.stockedGreen,
                               title: "No more blank screen",
                               detail: "Resuming a cook from the floating pill and then finishing it no longer shows a blank screen — it returns you home cleanly.")
            ]
        ),
        // ── 0.4.10 — Build 229 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "0.4.10",
            buildDate: "Build 229 · June 2026",
            headline: "Cooking pill knows when you're done",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "flame", color: Color.stockedGold,
                               title: "Pill clears on finish",
                               detail: "The floating ‘Cooking’ button now disappears the moment you press Finish Cooking — not just after rating the meal."),
                ChangelogEntry(icon: "exclamationmark.bubble.fill", color: Color.stockedInfo,
                               title: "Timer troubleshooting, on-device",
                               detail: "If the Lock Screen timer can't start, the cook screen now tells you exactly why and how to fix it — no computer needed.")
            ]
        ),
        // ── 0.4.9 — Build 228 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.4.9",
            buildDate: "Build 228 · June 2026",
            headline: "Never lose your place",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.uturn.backward.circle.fill", color: Color.stockedInfo,
                               title: "Tabs remember your place",
                               detail: "Switch tabs and come back exactly where you left — recipe open, cook in progress, all preserved. Tap the tab you're already on to jump back to its main page."),
                ChangelogEntry(icon: "flame.fill", color: Color.stockedGold,
                               title: "In Progress pill",
                               detail: "A floating ‘Cooking’ button appears on Home whenever a recipe is mid-cook — tap it to jump right back to your step.")
            ]
        ),
        // ── 0.4.8 — Build 227 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.4.8",
            buildDate: "Build 227 · June 2026",
            headline: "Cook timers on your Lock Screen",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "timer", color: Color.stockedGold,
                               title: "Live cooking timers",
                               detail: "Start a step timer and it appears on your Lock Screen and Dynamic Island, counting down live — so you can put the phone down and still see when the step is up.")
            ]
        ),
        // ── 0.4.7 — Build 226 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.4.7",
            buildDate: "Build 226 · June 2026",
            headline: "Tidied up",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "rectangle.badge.minus", color: Color.stockedGold,
                               title: "Streamlined Stats",
                               detail: "Removed the ‘Kitchen Wrapped’ recap — it showed the same numbers Kitchen Stats already covers. One place for your cooking stats.")
            ]
        ),
        // ── 0.4.6 — Build 225 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.4.6",
            buildDate: "Build 225 · June 2026",
            headline: "Widgets for your kitchen",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.grid.2x2.fill", color: Color.stockedGold,
                               title: "Home Screen widgets",
                               detail: "Add a Stocked widget to your Home Screen for an at-a-glance stock level, what's expiring, what's low, and tonight's planned meal."),
                ChangelogEntry(icon: "lock.fill", color: Color.stockedInfo,
                               title: "Lock Screen widgets",
                               detail: "Glance at your stock level or what's expiring right from the Lock Screen — circular, inline, and rectangular styles.")
            ]
        ),
        // ── 0.4.5 — Build 224 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.4.5",
            buildDate: "Build 224 · June 2026",
            headline: "Your Kitchen, Wrapped",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Your Kitchen, Wrapped",
                               detail: "Open Kitchen Stats and tap ‘Your Kitchen, Wrapped’ for a recap of your cooking story — meals cooked, best streak, your most-cooked and top-rated recipes, and roughly how much you've saved cooking at home.")
            ]
        ),
        // ── 0.4.4 — Build 223 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.4.4",
            buildDate: "Build 223 · June 2026",
            headline: "Edit Profile opens — for real this time",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.tap.fill", color: Color.stockedInfo,
                               title: "Settings sheets open first try",
                               detail: "Edit Profile and Notifications now open reliably on the first tap, using the same dependable path as the drawer's Quick Actions.")
            ]
        ),
        // ── 0.4.3 — Build 222 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.4.3",
            buildDate: "Build 222 · June 2026",
            headline: "Two stubborn bugs, gone",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "rectangle.compress.vertical", color: Color.stockedGold,
                               title: "Kitchen Transfer sits right",
                               detail: "The empty space above the title is gone — the screen now starts at the top where it should."),
                ChangelogEntry(icon: "hand.tap.fill", color: Color.stockedInfo,
                               title: "Edit Profile opens first try",
                               detail: "No more flashing closed and needing a second tap — Edit Profile and Notifications now open reliably the first time.")
            ]
        ),
        // ── 0.4.2 — Build 221 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.4.2",
            buildDate: "Build 221 · June 2026",
            headline: "Inventory at the speed of a swipe",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "slider.horizontal.below.rectangle", color: Color.stockedGreen,
                               title: "Drag to adjust",
                               detail: "The level bar on every inventory card is now a slider — drag it to set how much is left. Dragging to empty logs it and restocks your list automatically."),
                ChangelogEntry(icon: "square.grid.2x2.fill", color: Color.stockedGold,
                               title: "Zone heatmap",
                               detail: "Fridge, Freezer, Pantry and Staples chips now show a fill-level dot and item count, so you can spot which zone needs attention at a glance."),
                ChangelogEntry(icon: "checkmark.circle.fill", color: Color.stockedGreen,
                               title: "Used It Up",
                               detail: "One tap on an expiring item marks it finished — logged to your stats and added back to the grocery list if auto-add is on.")
            ]
        ),
        // ── 0.4.1 — Build 220 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.4.1",
            buildDate: "Build 220 · June 2026",
            headline: "Smarter shopping, real reminders",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "gauge.with.needle", color: Color.stockedGold,
                               title: "Running out soon",
                               detail: "The grocery list now spots items you'll run out of within days — based on how fast you actually use them — before they hit low."),
                ChangelogEntry(icon: "dollarsign.circle.fill", color: Color.stockedGreen,
                               title: "Price insights",
                               detail: "Suggestions show where each item has been cheapest over the last six months, from your own purchase history."),
                ChangelogEntry(icon: "lightbulb.fill", color: Color.stockedGold,
                               title: "Waste coaching",
                               detail: "Stats now calls out the item you toss most often, with a practical suggestion to stop the cycle."),
                ChangelogEntry(icon: "bell.badge.fill", color: Color.stockedInfo,
                               title: "Notifications are live",
                               detail: "Daily brief, day-before expiry alerts, a low-staples nudge, and a weekly meal-prep reminder — all configurable from the new Notifications settings.")
            ]
        ),
        // ── 0.4.0 — Build 219 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.4.0",
            buildDate: "Build 219 · June 2026",
            headline: "Your kitchen gets smart",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "flame.fill", color: Color.stockedGreen,
                               title: "Cookable sort",
                               detail: "A new sort in your Recipe Vault ranks recipes by what's in stock right now — and every card shows how many ingredients you already have."),
                ChangelogEntry(icon: "exclamationmark.triangle.fill", color: Color.stockedGold,
                               title: "Allergen warnings",
                               detail: "Saved recipes that conflict with your allergens now carry a warning badge, and your preferred cuisines float up in Cookable sort."),
                ChangelogEntry(icon: "calendar.badge.clock", color: Color.stockedInfo,
                               title: "Run-out predictions",
                               detail: "Inventory cards now show when an item will likely run out, learned from how fast you actually use it."),
                ChangelogEntry(icon: "book.fill", color: Color.stockedGold,
                               title: "Use it up — from your collection",
                               detail: "Expiring Soon now suggests your own saved recipes that use what's about to expire, before reaching for online ideas.")
            ]
        ),
        // ── 0.3.17 — Build 218 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "0.3.17",
            buildDate: "Build 218 · June 2026",
            headline: "Edit Profile that opens first try",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.tap", color: Color.stockedInfo,
                               title: "Edit Profile fixed",
                               detail: "It now opens on the first tap instead of flashing closed, and every row is fully tappable — tap anywhere on a row to expand it."),
                ChangelogEntry(icon: "checklist", color: Color.stockedGreen,
                               title: "A friendlier stock-goals quiz",
                               detail: "‘What does stocked mean to you?’ is now a quick step-by-step quiz with a progress bar — one food group at a time — instead of one long list.")
            ]
        ),
        // ── 0.3.14 — Build 215 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "0.3.14",
            buildDate: "Build 215 · June 2026",
            headline: "Screens sit where they should",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "rectangle.compress.vertical", color: Color.stockedGold,
                               title: "Top-aligned screens",
                               detail: "Fixed Kitchen Transfer (and any sheet that could float) so content starts at the top with the title in its usual place — no empty space above it."),
                ChangelogEntry(icon: "person.text.rectangle", color: Color.stockedInfo,
                               title: "Clearer Settings",
                               detail: "‘Redo Setup Quiz’ is now ‘Edit Profile’, which matches the quick editor it opens.")
            ]
        ),
        // ── 0.3.13 — Build 214 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "0.3.13",
            buildDate: "Build 214 · June 2026",
            headline: "Tidied up Kitchen Transfer",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "rectangle.compress.vertical", color: Color.stockedGold,
                               title: "No more wasted space",
                               detail: "The Kitchen Transfer screen now starts right at the top with the title in its usual place, instead of floating in the middle with empty space above it.")
            ]
        ),
        // ── 0.3.12 — Build 213 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "0.3.12",
            buildDate: "Build 213 · June 2026",
            headline: "Tidied up Kitchen Transfer",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "rectangle.compress.vertical", color: Color.stockedGold,
                               title: "No more wasted space",
                               detail: "The Kitchen Transfer screen now starts at the top with the title in its usual place, instead of a big empty gap.")
            ]
        ),
        // ── 0.3.11 — Build 212 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "0.3.11",
            buildDate: "Build 212 · June 2026",
            headline: "Organize items your way",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "tag", color: Color.stockedGold,
                               title: "Categories & Spots",
                               detail: "Give any item your own category (Snacks, Baking…) and note exactly where it lives (Door, Top shelf, Crisper). Categories are searchable."),
                ChangelogEntry(icon: "sparkles", color: Color.stockedGreen,
                               title: "Leaner & tidier",
                               detail: "Removed unused internal screens and components for a lighter, faster app.")
            ]
        ),
        // ── 0.3.10 — Build 211 (June 2026) ─────────────────────────────────────
        ChangelogVersion(
            version: "0.3.10",
            buildDate: "Build 211 · June 2026",
            headline: "Smarter grocery from your meal plan",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "cart.badge.minus", color: Color.stockedGreen,
                               title: "No more double-buying",
                               detail: "When you cook a meal from your plan, it’s now marked done — so generating a grocery list from your plan skips meals you’ve already made."),
                ChangelogEntry(icon: "wrench.and.screwdriver", color: Color.stockedCharcoal,
                               title: "Under-the-hood cleanup",
                               detail: "Removed unused settings that never did anything, tidying the app’s internals.")
            ]
        ),
        // ── 0.3.9 — Build 210 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.3.9",
            buildDate: "Build 210 · June 2026",
            headline: "Your recipes now remember how they went",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "star.fill", color: Color.stockedGold,
                               title: "Per-Recipe Ratings",
                               detail: "Each saved recipe shows its average star rating from every time you’ve cooked and rated it."),
                ChangelogEntry(icon: "clock.arrow.circlepath", color: Color.stockedGold,
                               title: "Cook History",
                               detail: "See how many times you’ve made a recipe and when you last cooked it, right on its page.")
            ]
        ),
        // ── 0.3.8 — Build 209 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.3.8",
            buildDate: "Build 209 · June 2026",
            headline: "Stability fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "wrench.and.screwdriver", color: Color.stockedCharcoal,
                               title: "Under-the-hood cleanup",
                               detail: "Removed some duplicate recipe-import code that was conflicting with the existing importer. Importing from a link, photo, or text works exactly as before.")
            ]
        ),
        // ── 0.3.7 — Build 208 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.3.7",
            buildDate: "Build 208 · June 2026",
            headline: "See your spending, waste, and what to rebuy",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "dollarsign.circle", color: Color.stockedGold,
                               title: "Spending Breakdown",
                               detail: "Stats now shows what you’ve spent this month, by store, from your receipts and price history."),
                ChangelogEntry(icon: "trash", color: Color.stockedGreen,
                               title: "Food Waste Tracking",
                               detail: "When you toss something past its expiry, Stats tallies how many items — and roughly how much money — you’re wasting each month."),
                ChangelogEntry(icon: "arrow.clockwise.circle", color: Color.stockedInfo,
                               title: "Reorder Soon",
                               detail: "Stocked learns how fast you go through things and lists what’s about to run out, with a one-tap Add to your list.")
            ]
        ),
        // ── 0.3.6 — Build 207 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.3.6",
            buildDate: "Build 207 · June 2026",
            headline: "Import recipes from a photo or pasted text",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "camera.viewfinder", color: Color.stockedGreen,
                               title: "Snap or Paste a Recipe",
                               detail: "The import sheet now has Link, Photo, and Text modes. Photograph a cookbook page or screenshot and Stocked reads it on-device; or paste a recipe (or a social caption) and it pulls out the ingredients and steps.")
            ]
        ),
        // ── 0.3.5 — Build 206 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.3.5",
            buildDate: "Build 206 · June 2026",
            headline: "Import recipes from the web",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "link.badge.plus", color: Color.stockedGreen,
                               title: "Save Any Recipe by Link",
                               detail: "Tap the new link button in My Collection, paste a recipe URL from almost any cooking site, and Stocked pulls in the ingredients, steps, photo, and timing — preview it, then save it to your collection.")
            ]
        ),
        // ── 0.3.4 — Build 205 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.3.4",
            buildDate: "Build 205 · June 2026",
            headline: "Never run out of your essentials",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGreen,
                               title: "Par Levels & Auto-Reorder",
                               detail: "Set a “keep at least N in stock” minimum on any item in its editor. Drop below it and Stocked flags it to rebuy — automatically adding it to your grocery list when Auto-add is on.")
            ]
        ),
        // ── 0.3.3 — Build 204 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.3.3",
            buildDate: "Build 204 · June 2026",
            headline: "Ready to Cook now matches Browse",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.circle", color: Color.stockedGreen,
                               title: "Same Recipes, Filtered to What You Have",
                               detail: "Ready to Cook Now pulls from the same recipe collection as the Browse tab, showing the ones you can actually make right now from your inventory.")
            ]
        ),
        // ── 0.3.2 — Build 203 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.3.2",
            buildDate: "Build 203 · June 2026",
            headline: "Quick Update on Home + better recipe photos",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "text.bubble.fill", color: Color.stockedGold,
                               title: "Quick Update, Front and Center",
                               detail: "Quick Update moved out of the menu and onto your Home screen as a tap-anywhere card — just say what you used, bought, or ran out of. Cook Now and Cook Later resize to fit so everything stays on one screen."),
                ChangelogEntry(icon: "photo", color: Color.stockedGreen,
                               title: "Recipe Photos That Match",
                               detail: "Recipes without an exact photo now show a real picture of the right kind of dish (a beef dish for a steak) instead of a random mismatch — and fall back to a clean emoji when nothing fits.")
            ]
        ),
        // ── 0.3.1 — Build 202 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.3.1",
            buildDate: "Build 202 · June 2026",
            headline: "Know how stocked your kitchen really is",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "target", color: Color.stockedGreen,
                               title: "Kitchen Goals",
                               detail: "Tap the new prompt in your Daily Brief to pick the staples you like to keep on hand. Your “Inventory Status” then reflects the share of those staples you actually have — a real stock level instead of a rough average."),
                ChangelogEntry(icon: "checklist", color: Color.stockedGold,
                               title: "See What’s Low at a Glance",
                               detail: "Once it’s set up, the Brief tracks how many of your staples are running low, and you can edit your list anytime.")
            ]
        ),
        // ── 0.3.0 — Build 201 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.3.0",
            buildDate: "Build 201 · June 2026",
            headline: "More inventory polish under the hood",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "wrench.and.screwdriver", color: Color.stockedGreen,
                               title: "Edit & Add Sheets Streamlined",
                               detail: "Restructured the item editor and the add-item detail sheet internally for faster, more reliable rendering. No visible changes.")
            ]
        ),
        // ── 0.2.99 — Build 200 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.99",
            buildDate: "Build 200 · June 2026",
            headline: "Inventory screen performance",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "speedometer", color: Color.stockedGreen,
                               title: "Snappier Inventory",
                               detail: "Restructured the Inventory screen behind the scenes for faster, more reliable rendering. No visible changes — everything works exactly as before.")
            ]
        ),
        // ── 0.2.98 — Build 199 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.98",
            buildDate: "Build 199 · June 2026",
            headline: "Rename carries into your grocery list",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "pencil.and.list.clipboard", color: Color.stockedGold,
                               title: "Rename Follows the Recipe",
                               detail: "Renaming a recipe now also updates its group in your grocery list, so the names always match."),
                ChangelogEntry(icon: "checkmark.seal", color: Color.stockedGreen,
                               title: "Under-the-Hood Cleanup",
                               detail: "Tidied internal plumbing for recipe actions and slimmed the cook-overview screen for snappier, more reliable rendering.")
            ]
        ),
        // ── 0.2.97 — Build 198 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.97",
            buildDate: "Build 198 · June 2026",
            headline: "Export reliability",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.and.arrow.up", color: Color.stockedGold,
                               title: "Data Export Fix",
                               detail: "Fixed a case where exporting your data could hand the share sheet an empty result without warning. It now reports the problem instead of failing silently."),
                ChangelogEntry(icon: "doc.badge.gearshape", color: Color.stockedGreen,
                               title: "Quieter Failures, Louder Logs",
                               detail: "Backups and CSV export now record a clear log if a write ever fails, so issues are easier to track down.")
            ]
        ),
        // ── 0.2.96 — Build 197 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.96",
            buildDate: "Build 197 · June 2026",
            headline: "Recipe page alignment fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.left.and.right", color: Color.stockedGold,
                               title: "Recipe Title Alignment",
                               detail: "Fixed the recipe title and servings row sitting against the left edge on the cook-overview page — they now line up with everything else."),
                ChangelogEntry(icon: "ruler", color: Color.stockedGreen,
                               title: "Layout Consistency",
                               detail: "Tidied up how the app measures the screen behind the scenes so sizing stays consistent across iPhone, iPad, and split-screen.")
            ]
        ),
        // ── 0.2.95 — Build 196 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.95",
            buildDate: "Build 196 · June 2026",
            headline: "Recipe page alignment fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.left.and.right", color: Color.stockedGold,
                               title: "Recipe Detail Alignment",
                               detail: "Fixed recipe pages where the content sat off to the left edge. Tapping a recipe now lines up correctly.")
            ]
        ),
        // ── 0.2.94 — Build 195 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.94",
            buildDate: "Build 195 · June 2026",
            headline: "Layout fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.left.and.right", color: Color.stockedGold,
                               title: "Screen Alignment Fix",
                               detail: "Addressed content that could sit off to the side on scrolling screens, so pages line up properly again.")
            ]
        ),
        // ── 0.2.93 — Build 194 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.93",
            buildDate: "Build 194 · June 2026",
            headline: "Build fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hammer", color: Color.stockedGold,
                               title: "Internal Build Fix",
                               detail: "Fixed a wiring issue behind recipe rename and delete. Both work as intended.")
            ]
        ),
        // ── 0.2.92 — Build 193 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.92",
            buildDate: "Build 193 · June 2026",
            headline: "Build fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hammer", color: Color.stockedGold,
                               title: "Internal Build Fix",
                               detail: "Resolved a compile issue on the recipe detail screen from the last update. Rename and delete work exactly as before.")
            ]
        ),
        // ── 0.2.91 — Build 192 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.91",
            buildDate: "Build 192 · June 2026",
            headline: "Button styles & a tidier edge",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.on.circle", color: Color.stockedGold,
                               title: "Choose Your Button Shape & Size",
                               detail: "In Settings ▸ Appearance, pick Circle, Pill, or Rounded Square and set the size — applied to Cook Now, Cook Later, Foods, Moods, and Surprise Me."),
                ChangelogEntry(icon: "rectangle.lefthalf.inset.filled", color: Color.stockedGreen,
                               title: "Slimmer Menu Handle",
                               detail: "The left menu handle is now a thin edge grip instead of a big tab, so it no longer covers your recipes and lists.")
            ]
        ),
        // ── 0.2.90 — Build 191 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.90",
            buildDate: "Build 191 · June 2026",
            headline: "Rename & delete recipes",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "pencil", color: Color.stockedGold,
                               title: "Rename Any Recipe",
                               detail: "Open a recipe and tap ••• to rename it — the new name shows everywhere, including your grocery list. Long titles, tamed."),
                ChangelogEntry(icon: "trash", color: Color.stockedGreen,
                               title: "Delete Whole Recipes & Groups",
                               detail: "Delete an entire recipe from the ••• menu, and clear a whole recipe's items from the grocery list in one tap — no more removing items one by one.")
            ]
        ),
        // ── 0.2.89 — Build 190 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.89",
            buildDate: "Build 190 · June 2026",
            headline: "Build fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hammer", color: Color.stockedGold,
                               title: "Internal Build Fix",
                               detail: "Resolved a compile issue in last build's internal cleanup. No changes to how the app looks or works.")
            ]
        ),
        // ── 0.2.88 — Build 189 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.88",
            buildDate: "Build 189 · June 2026",
            headline: "Behind-the-scenes cleanup",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.split.2x2", color: Color.stockedGold,
                               title: "Code Tidy-Up",
                               detail: "Reorganized the recipe screens internally for easier maintenance. No changes to how the app looks or works.")
            ]
        ),
        // ── 0.2.87 — Build 188 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.87",
            buildDate: "Build 188 · June 2026",
            headline: "Behind-the-scenes cleanup",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "wrench.and.screwdriver", color: Color.stockedGold,
                               title: "Under-the-Hood Improvements",
                               detail: "Internal cleanup to make the recipe import and grocery features more reliable and easier to maintain. No changes to how the app looks or works.")
            ]
        ),
        // ── 0.2.86 — Build 187 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.86",
            buildDate: "Build 187 · June 2026",
            headline: "More accurate recipe import",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checklist", color: Color.stockedGreen,
                               title: "Cleaner Imported Ingredients",
                               detail: "Imported ingredients now separate name, amount, and units more reliably, merge duplicates, and flag anything that looks off so you can double-check it."),
                ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGold,
                               title: "More Reliable & Repeatable",
                               detail: "Imports recover better from odd formatting, retry once before giving up, and re-importing the same recipe stays instant and free.")
            ]
        ),
        // ── 0.2.85 — Build 186 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.85",
            buildDate: "Build 186 · June 2026",
            headline: "Recipe-to-grocery & faster imports",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "cart.badge.plus", color: Color.stockedGreen,
                               title: "Add to Grocery from Any Recipe",
                               detail: "Tap 'Add missing to grocery list' right on a new or imported recipe — it skips what you already have and tags items by recipe."),
                ChangelogEntry(icon: "bolt", color: Color.stockedGold,
                               title: "Faster, Cheaper Re-Imports",
                               detail: "Importing the same recipe again is now instant and works offline — no re-processing needed.")
            ]
        ),
        // ── 0.2.84 — Build 185 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.84",
            buildDate: "Build 185 · June 2026",
            headline: "Smarter recipe import",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "wand.and.stars", color: Color.stockedGold,
                               title: "AI-Assisted Import",
                               detail: "Imported recipes are now cleaned up automatically — ingredient names and amounts separated correctly, steps tidied, and times made readable."),
                ChangelogEntry(icon: "doc.plaintext", color: Color.stockedGreen,
                               title: "Show Original Text",
                               detail: "Tap 'Show original text' on an imported recipe to see exactly what was pulled from the page, so you can double-check anything.")
            ]
        ),
        // ── 0.2.83 — Build 184 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.83",
            buildDate: "Build 184 · June 2026",
            headline: "Cleaner recipe form & step timers",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "textformat", color: Color.stockedGold,
                               title: "Readable Text Everywhere",
                               detail: "Section titles and imported ingredient names now use normal capitalization instead of ALL CAPS or all lowercase."),
                ChangelogEntry(icon: "list.bullet", color: Color.stockedGreen,
                               title: "Smarter Ingredient Parsing",
                               detail: "Imported ingredients now split into name and amount correctly — things like '12 strawberries, sliced' and '2 4-ounce balls burrata' read the way you'd expect."),
                ChangelogEntry(icon: "timer", color: Color.stockedGreen,
                               title: "Step Timers in the Editor",
                               detail: "Steps that mention a time now show the timer the cook mode will use (e.g. a 20 min badge for 'bake 20 minutes'), updating as you type.")
            ]
        ),
        // ── 0.2.82 — Build 183 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.82",
            buildDate: "Build 183 · June 2026",
            headline: "New Recipe form overhaul",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.and.pencil", color: Color.stockedGold,
                               title: "Bigger, Complete Recipe Form",
                               detail: "The New Recipe screen now has roomier text fields and full Photo, Ingredients, Steps, and Notes sections — so everything you import is visible and editable, not just the title and times."),
                ChangelogEntry(icon: "photo", color: Color.stockedGreen,
                               title: "Recipe Photos & Steps Pull In",
                               detail: "Imported recipes now show their photo and let you add your own, and the ingredients and steps that come in are fully editable."),
                ChangelogEntry(icon: "clock", color: Color.stockedGreen,
                               title: "Readable Prep & Cook Times",
                               detail: "Times now read as '20 min' instead of codes like 'PT20M', and cook time falls back to total time when a recipe doesn't list it separately.")
            ]
        ),
        // ── 0.2.81 — Build 182 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.81",
            buildDate: "Build 182 · June 2026",
            headline: "Recipe importing works",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.circle", color: Color.stockedGreen,
                               title: "Share & Link Import Fixed",
                               detail: "Fixed the bug that cancelled recipe imports before they finished. Sharing a recipe link into Stocked now reads it reliably.")
            ]
        ),
        // ── 0.2.80 — Build 181 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.80",
            buildDate: "Build 181 · June 2026",
            headline: "Link import fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.down.doc", color: Color.stockedGold,
                               title: "Reads More Recipe Sites",
                               detail: "Fixed importing from major recipe sites that were previously refusing the request.")
            ]
        ),
        // ── 0.2.79 — Build 180 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.79",
            buildDate: "Build 180 · June 2026",
            headline: "Imports even more pages",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "doc.text.magnifyingglass", color: Color.stockedGold,
                               title: "Smarter Link Import",
                               detail: "When a shared link doesn't have structured recipe data, Stocked now reads the page text as a fallback so more links can still import.")
            ]
        ),
        // ── 0.2.78 — Build 179 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.78",
            buildDate: "Build 179 · June 2026",
            headline: "Better recipe importing",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "link.badge.plus", color: Color.stockedGold,
                               title: "Imports More Sites",
                               detail: "Improved reading recipes from shared links — more recipe websites now import cleanly.")
            ]
        ),
        // ── 0.2.77 — Build 178 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.77",
            buildDate: "Build 178 · June 2026",
            headline: "Stability fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal", color: Color.stockedGreen,
                               title: "Build Fix",
                               detail: "Resolved an internal build issue so recent improvements run correctly.")
            ]
        ),
        // ── 0.2.76 — Build 177 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.76",
            buildDate: "Build 177 · June 2026",
            headline: "More recipe sources",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.stack.3d.up", color: Color.stockedGold,
                               title: "Richer Recipe Browse",
                               detail: "Browse now pulls from more recipe sources at once for better variety, while keeping image quality high."),
                ChangelogEntry(icon: "text.magnifyingglass", color: Color.stockedGreen,
                               title: "Smarter Suggestions",
                               detail: "Ingredient suggestions now fall back to an online lookup when needed, so unusual items still autocomplete.")
            ]
        ),
        // ── 0.2.75 — Build 176 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.75",
            buildDate: "Build 176 · June 2026",
            headline: "Share import diagnostics",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "stethoscope", color: Color.stockedCharcoal,
                               title: "Sharing Reliability",
                               detail: "Added clearer messaging when a shared recipe can't be read, so it no longer fails silently.")
            ]
        ),
        // ── 0.2.74 — Build 175 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.74",
            buildDate: "Build 175 · June 2026",
            headline: "Share-to-Stocked fixes",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.and.arrow.down", color: Color.stockedGreen,
                               title: "Sharing Recipes In",
                               detail: "Fixed sharing a recipe into Stocked from another app — it now opens reliably and drops you straight into the recipe editor."),
                ChangelogEntry(icon: "bolt.heart", color: Color.stockedGold,
                               title: "Faster Launch",
                               detail: "Fixed a rare case where the app could hang on the opening screen.")
            ]
        ),
        // ── 0.2.73 — Build 174 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.73",
            buildDate: "Build 174 · June 2026",
            headline: "Four ways to add a recipe",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "plus.rectangle.on.rectangle", color: Color.stockedGold,
                               title: "New Add-Recipe Menu",
                               detail: "Adding a recipe now offers four options: start from scratch, import from a website link, import from a screenshot, or paste the text — each opens the editor so you can review before saving."),
                ChangelogEntry(icon: "doc.text.viewfinder", color: Color.stockedGreen,
                               title: "Screenshot & Text Import",
                               detail: "Read a recipe straight from a saved screenshot, or paste any recipe text and we'll structure the ingredients and steps for you.")
            ]
        ),
        // ── 0.2.72 — Build 173 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.72",
            buildDate: "Build 173 · June 2026",
            headline: "Recipe photos are back",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "photo.on.rectangle", color: Color.stockedGold,
                               title: "Images in Ready to Cook",
                               detail: "Suggested recipes now show a food photo instead of a plain icon — pulled from recipe-photo sources and matched to the dish where possible.")
            ]
        ),
        // ── 0.2.71 — Build 172 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.71",
            buildDate: "Build 172 · June 2026",
            headline: "Build fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal", color: Color.stockedGreen,
                               title: "Stability Fix",
                               detail: "Resolved a compile issue in the new Quick Update flow. No feature changes.")
            ]
        ),
        // ── 0.2.70 — Build 171 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.70",
            buildDate: "Build 171 · June 2026",
            headline: "A more polished look",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "paintpalette", color: Color.stockedGold,
                               title: "Consistent Design",
                               detail: "Tightened up corners and colors across the app so everything feels more cohesive and considered."),
                ChangelogEntry(icon: "textformat", color: Color.stockedGreen,
                               title: "Signature Touch",
                               detail: "The period in “Stocked.” now wears a touch of gold — a small detail, everywhere it counts.")
            ]
        ),
        // ── 0.2.69 — Build 170 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.69",
            buildDate: "Build 170 · June 2026",
            headline: "Keep your pantry accurate, effortlessly",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Tidy Up Your Pantry",
                               detail: "The Daily Brief now flags items that are likely used up or expired, so you can clear them out in a couple of taps and keep your inventory honest."),
                ChangelogEntry(icon: "text.bubble", color: Color.stockedGreen,
                               title: "Quick Update — Just Tell Me",
                               detail: "Type what changed in plain language — \"finished the milk, used half the rice, bought tofu\" — and Stocked. turns it into changes you confirm. Find it in the menu."),
                ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGold,
                               title: "Smarter Stock Tracking",
                               detail: "Using items up after cooking and adjusting amounts now flow through one consistent, confirm-first system.")
            ]
        ),
        // ── 0.2.68 — Build 169 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.68",
            buildDate: "Build 169 · June 2026",
            headline: "Receipt cleanup & store picker fixes",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "doc.text.viewfinder", color: Color.stockedGold,
                               title: "Cleaner Receipt Scans",
                               detail: "Barcodes, number strings, and stray symbols no longer get added as items when you scan a receipt."),
                ChangelogEntry(icon: "storefront", color: Color.stockedGreen,
                               title: "Preferred Store Opens",
                               detail: "Tapping Preferred Store in the menu now opens the store screen as expected."),
                ChangelogEntry(icon: "paintbrush", color: Color.stockedGold,
                               title: "Themed Store Picker",
                               detail: "The Choose Store screen now matches the app's look instead of a plain white list.")
            ]
        ),
        // ── 0.2.67 — Build 168 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.67",
            buildDate: "Build 168 · June 2026",
            headline: "Build fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal", color: Color.stockedGreen,
                               title: "Stability Fix",
                               detail: "Resolved a compile issue from the previous build. No feature changes.")
            ]
        ),
        // ── 0.2.66 — Build 167 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.66",
            buildDate: "Build 167 · June 2026",
            headline: "Store pop-out, backup info & Household premium",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "storefront", color: Color.stockedGold,
                               title: "Preferred Store Pop-Out",
                               detail: "Your preferred store opens in its own screen now, with the nearby-stores finder moved in alongside it."),
                ChangelogEntry(icon: "icloud", color: Color(red:0.27,green:0.56,blue:0.87),
                               title: "Last Backup Shown",
                               detail: "Backup to iCloud now tells you when you last backed up."),
                ChangelogEntry(icon: "person.2.badge.key", color: Color.stockedGreen,
                               title: "Household Sync Goes Premium",
                               detail: "Household Sync is now a premium feature — one purchase by the household owner covers everyone in the family.")
            ]
        ),
        // ── 0.2.65 — Build 166 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.65",
            buildDate: "Build 166 · June 2026",
            headline: "A big polish pass",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "house", color: Color.stockedGold,
                               title: "Reworked Home",
                               detail: "The title and greeting now stay put while you scroll, and the Cook buttons shrink to pills as you scroll down — expanding again at the top."),
                ChangelogEntry(icon: "rectangle.bottombar.badge.arrow.up", color: Color.stockedCharcoal,
                               title: "Tidier Navigation",
                               detail: "The bottom tab bar tucks away as you scroll (tap the handle to bring it back), and the Daily Brief now takes over the screen on its own."),
                ChangelogEntry(icon: "calendar.badge.clock", color: Color.stockedGreen,
                               title: "Daily Brief Upgrades",
                               detail: "At-a-glance stats moved here, household activity is now summarized, and the Add to Meal, recipe suggestions, and Build Meal actions all work reliably."),
                ChangelogEntry(icon: "slider.horizontal.below.square.filled.and.square", color: Color.stockedGold,
                               title: "Smarter Add Item",
                               detail: "Set how much you have right on the first step (e.g. 6 of 12), swipe down to back out of the flow, and it closes automatically when you're done."),
                ChangelogEntry(icon: "magnifyingglass", color: Color.stockedGreen,
                               title: "Global Search That Works",
                               detail: "Every result is now tappable — recipes open, ingredients show details to learn more, and Cancel properly dismisses the keyboard."),
                ChangelogEntry(icon: "doc.text.viewfinder", color: Color.stockedGold,
                               title: "Better Receipt Scanning",
                               detail: "Receipt scanning now factors in the store to read items more accurately."),
                ChangelogEntry(icon: "hand.tap", color: Color.stockedCharcoal,
                               title: "Guided Tour",
                               detail: "New here? A first-run walkthrough points out the menu and each tab."),
                ChangelogEntry(icon: "textformat.size", color: Color.stockedGreen,
                               title: "Accessibility",
                               detail: "The app now adapts to larger text sizes and display zoom settings.")
            ]
        ),
        // ── 0.2.64 — Build 165 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.64",
            buildDate: "Build 165 · June 2026",
            headline: "Build Meal button fixed",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "fork.knife", color: Color.stockedGreen,
                               title: "Build Meal Now Works",
                               detail: "The Build Meal button on the Expiring Soon and Low Stock lists now opens the meal planner as expected. It wasn't responding before.")
            ]
        ),
        // ── 0.2.63 — Build 164 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.63",
            buildDate: "Build 164 · June 2026",
            headline: "Join code generation",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "qrcode", color: Color.stockedGreen,
                               title: "Share Code Reliability",
                               detail: "The household share now waits longer for iCloud to finish setting up, so the 8-character join code generates reliably.")
            ]
        ),
        // ── 0.2.62 — Build 163 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.62",
            buildDate: "Build 163 · June 2026",
            headline: "Household sync fixed",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.icloud", color: Color.stockedGreen,
                               title: "Sync & Join Code Work Again",
                               detail: "Fixed the owner's household connection being lost after restarting the app, which caused 'Couldn't reach the shared kitchen' and prevented the join code from generating.")
            ]
        ),
        // ── 0.2.61 — Build 162 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.61",
            buildDate: "Build 162 · June 2026",
            headline: "Cleaner home + sync diagnostics",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "house", color: Color.stockedGold,
                               title: "Streamlined Home",
                               detail: "Removed the getting-started card from the Home screen."),
                ChangelogEntry(icon: "person.2.badge.key", color: Color.stockedGreen,
                               title: "Join-Code Troubleshooting",
                               detail: "If a household join code can't be generated, the app now tells you why and attempts to recreate the share automatically.")
            ]
        ),
        // ── 0.2.60 — Build 161 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.60",
            buildDate: "Build 161 · June 2026",
            headline: "Build fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "wrench.and.screwdriver", color: Color.stockedGold,
                               title: "Compile Fix",
                               detail: "Resolved a missing import that prevented the previous build from compiling. Includes all of Build 160's changes.")
            ]
        ),
        // ── 0.2.59 — Build 160 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.59",
            buildDate: "Build 160 · June 2026",
            headline: "Account deletion + diet-tag fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "person.crop.circle.badge.xmark", color: Color.stockedGold,
                               title: "Delete Account",
                               detail: "You can now permanently delete your account and all data from Settings → Data & Account."),
                ChangelogEntry(icon: "leaf", color: Color.stockedGreen,
                               title: "Smarter Dietary Tags",
                               detail: "Fixed recipes being mislabeled vegan or vegetarian when they actually contain meat or seafood.")
            ]
        ),
        // ── 0.2.58 — Build 159 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.58",
            buildDate: "Build 159 · June 2026",
            headline: "Crash fix (CloudKit)",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "exclamationmark.triangle.fill", color: Color.stockedGreen,
                               title: "Fixed a Sync-Related Crash",
                               detail: "Resolved a memory bug in the iCloud sync code that could crash the app. CloudKit operations are now kept alive until they finish.")
            ]
        ),
        // ── 0.2.57 — Build 158 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.57",
            buildDate: "Build 158 · June 2026",
            headline: "Household join code fixed",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "person.2.badge.key", color: Color.stockedGold,
                               title: "Share Code Now Generates",
                               detail: "Creating a household now reliably produces an 8-character join code to share with family, and the code stays visible after restarting the app. If you already created a household with no code, tap 'Sync now' to generate it.")
            ]
        ),
        // ── 0.2.56 — Build 157 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.56",
            buildDate: "Build 157 · June 2026",
            headline: "Receipt scanner: cleaner results",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "doc.text.magnifyingglass", color: Color.stockedGold,
                               title: "No More Receipt Junk",
                               detail: "The scanner now also strips out store names, addresses, phone numbers, totals, tax, card/auth details, dates, and slogans — not just non-food products — so only real items land in your pantry.")
            ]
        ),
        // ── 0.2.55 — Build 156 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.55",
            buildDate: "Build 156 · June 2026",
            headline: "Receipt scanner: food only",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checklist", color: Color.stockedGold,
                               title: "Food-Only Receipt Scanning",
                               detail: "Scanning a receipt now keeps only food and drinks. Cleaning supplies, paper goods, pet food, medicine, toiletries, kitchen tools, storage bags, and stray price/number lines are filtered out automatically.")
            ]
        ),
        // ── 0.2.54 — Build 155 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.54",
            buildDate: "Build 155 · June 2026",
            headline: "Save recipes with a tap",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "heart.fill", color: Color.stockedGold,
                               title: "Heart to Save",
                               detail: "When browsing a recipe, tap the heart in the top-left to save it to My Collection. Tap again to remove it. The heart fills in when a recipe is already saved.")
            ]
        ),
        // ── 0.2.53 — Build 154 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.53",
            buildDate: "Build 154 · June 2026",
            headline: "Dark-mode polish & refresh fixes",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "circle.lefthalf.filled", color: Color.stockedGold,
                               title: "Settings Toggles Fixed",
                               detail: "The Measurements and Button Shape selectors no longer show the chosen option as a blank gold block — the selected label is now readable."),
                ChangelogEntry(icon: "arrow.clockwise", color: Color.stockedGreen,
                               title: "Ready-to-Cook Refreshes",
                               detail: "The recipe suggestions now update when your pantry changes — restock or add an ingredient and a recipe that's now ready will reflect it."),
                ChangelogEntry(icon: "moon.stars.fill", color: Color.stockedCharcoal,
                               title: "Dark Mode Consistency",
                               detail: "The Kitchen Transfer screen and the recipe Estimated Nutrition bar now follow dark mode instead of showing a light/tan panel."),
            ]
        ),
        // ── 0.2.52 — Build 153 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.52",
            buildDate: "Build 153 · June 2026",
            headline: "Split presets & simpler menu",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "rectangle.split.2x1", color: Color.stockedGold,
                               title: "Split-View Size Presets",
                               detail: "On iPad, choose how the inventory list and item editor share the screen — List ⅓, Even, or List ⅔ — from buttons in the editor header. Your choice is remembered. (Replaces dragging the divider.)"),
                ChangelogEntry(icon: "sidebar.left", color: Color.stockedCharcoal,
                               title: "Simpler Menu Tab",
                               detail: "The menu tab now opens with a tap (and closes by tapping the tab or outside it). The drag-to-open and drag-to-move gestures were removed for a cleaner, more reliable feel.")
            ]
        ),
        // ── 0.2.51 — Build 152 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.51",
            buildDate: "Build 152 · June 2026",
            headline: "Divider follows your finger",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.draw", color: Color.stockedGold,
                               title: "Split Divider Tracks Smoothly",
                               detail: "The split-view divider now glides with your finger as you drag it, instead of only jumping when you let go.")
            ]
        ),
        // ── 0.2.50 — Build 151 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.50",
            buildDate: "Build 151 · June 2026",
            headline: "Smooth menu-tab drag",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.draw", color: Color.stockedGold,
                               title: "Smooth Menu Tab & Drawer",
                               detail: "Dragging the menu tab — both sideways to open the drawer and up/down to reposition it — is now smooth. It no longer redraws the screen behind it while you drag.")
            ]
        ),
        // ── 0.2.49 — Build 150 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.49",
            buildDate: "Build 150 · June 2026",
            headline: "Smoother divider drag",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.draw", color: Color.stockedGold,
                               title: "Smoother Split-View Divider",
                               detail: "Dragging the divider between the list and the item editor on iPad is now smooth — the panes resize cleanly when you let go instead of redrawing on every frame.")
            ]
        ),
        // ── 0.2.48 — Build 149 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.48",
            buildDate: "Build 149 · June 2026",
            headline: "Smoother iPad gestures",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.draw", color: Color.stockedGold,
                               title: "Smoother Dragging on iPad",
                               detail: "The split-view divider and the draggable menu tab now move smoothly instead of stuttering. (This time done without affecting the layout.)")
            ]
        ),
        // ── 0.2.47 — Build 148 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.47",
            buildDate: "Build 148 · June 2026",
            headline: "Layout fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.uturn.backward.circle.fill", color: Color.stockedGreen,
                               title: "Fixed: iPad Layout",
                               detail: "Reverted a change that broke the iPad layout. Everything is back to normal — tabs, headers, and navigation display correctly again.")
            ]
        ),
        // ── 0.2.45 — Build 146 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.45",
            buildDate: "Build 146 · June 2026",
            headline: "iPad tab state restored",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.on.square", color: Color.stockedGold,
                               title: "iPad: Tabs Remember Their Place",
                               detail: "Switching between tabs on iPad now keeps each tab's scroll position and open sections, instead of resetting. Re-enabled now that the memory issue is fully resolved.")
            ]
        ),
        // ── 0.2.44 — Build 145 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.44",
            buildDate: "Build 145 · June 2026",
            headline: "iPad crash fixed (profiler-confirmed)",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal.fill", color: Color.stockedGreen,
                               title: "Fixed: Runaway Memory on iPad",
                               detail: "A memory profile pinpointed it: a small text-formatting helper used on every list row was rebuilding a text-matching engine each time it ran, piling up memory on the Grocery, Inventory, and recipe screens until the app was closed. It now builds that engine once. Screens stay fast and light.")
            ]
        ),
        // ── 0.2.43 — Build 144 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.43",
            buildDate: "Build 144 · June 2026",
            headline: "Recipe de-dup efficiency",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal.fill", color: Color.stockedGreen,
                               title: "Fixed: Runaway Memory on iPad",
                               detail: "Pinpointed the exact cause with a memory profile: recipe de-duplication was re-reading every recipe's ingredients over and over, creating millions of temporary text objects and exhausting memory. It now reads each recipe once, so the app stays fast and light.")
            ]
        ),
        // ── 0.2.42 — Build 143 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.42",
            buildDate: "Build 143 · June 2026",
            headline: "Observable cache fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal.fill", color: Color.stockedGreen,
                               title: "Fixed: App Closing on iPad (root cause)",
                               detail: "Tracked down the shared cause behind the crashes on Home, Ready to Cook, and Grocery: a piece of cached data was being rebuilt in a way that could trigger an endless refresh loop. Fixed at the source, so it no longer affects any screen.")
            ]
        ),
        // ── 0.2.41 — Build 142 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.41",
            buildDate: "Build 142 · June 2026",
            headline: "iPad performance",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.circle.fill", color: Color.stockedGreen,
                               title: "Fixed: App Closing on iPad",
                               detail: "Fixed the runaway memory that closed the app on iPad — both when sitting idle and when opening Ready to Cook. Screens now load efficiently and Ready to Cook computes its matches just once.")
            ]
        ),
        // ── 0.2.40 — Build 141 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.40",
            buildDate: "Build 141 · June 2026",
            headline: "Diagnostic build",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "stethoscope", color: Color.stockedGold,
                               title: "iPad Performance Diagnostic",
                               detail: "Narrowing down an iPad memory issue — the Inventory screen is temporarily simplified for this test. Temporary build.")
            ]
        ),
        // ── 0.2.39 — Build 140 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.39",
            buildDate: "Build 140 · June 2026",
            headline: "Diagnostic build",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "stethoscope", color: Color.stockedGold,
                               title: "iPad Performance Diagnostic",
                               detail: "On iPad, screens now load one at a time while we isolate a memory issue specific to iPad. Temporary test build.")
            ]
        ),
        // ── 0.2.38 — Build 139 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.38",
            buildDate: "Build 139 · June 2026",
            headline: "Diagnostic build",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "stethoscope", color: Color.stockedGold,
                               title: "Performance Diagnostic",
                               detail: "Some background sync features are temporarily paused while we isolate a memory issue. Temporary test build.")
            ]
        ),
        // ── 0.2.37 — Build 138 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.37",
            buildDate: "Build 138 · June 2026",
            headline: "Diagnostic build",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "stethoscope", color: Color.stockedGold,
                               title: "Performance Diagnostic",
                               detail: "The Ready to Cook screen is temporarily simplified while we isolate a memory issue. Everything else is unchanged. Temporary test build.")
            ]
        ),
        // ── 0.2.36 — Build 137 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.36",
            buildDate: "Build 137 · June 2026",
            headline: "iCloud sync loop fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.circle.fill", color: Color.stockedGreen,
                               title: "Fixed: App Closing on iPad",
                               detail: "Found and fixed the real cause: when a shared household was active, the iCloud pantry sync could get stuck in a loop on launch, using runaway memory until the system closed the app. Sync now applies updates safely without looping.")
            ]
        ),
        // ── 0.2.35 — Build 136 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.35",
            buildDate: "Build 136 · June 2026",
            headline: "Ready to Cook efficiency",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.circle.fill", color: Color.stockedGreen,
                               title: "Fixed: App Closing on iPad",
                               detail: "Resolved a bug in the Ready to Cook screen that caused the app to use runaway memory and be shut down by the system after a short time. The screen now computes its matches once and efficiently.")
            ]
        ),
        // ── 0.2.34 — Build 135 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.34",
            buildDate: "Build 135 · June 2026",
            headline: "Diagnostic build",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "stethoscope", color: Color.stockedGold,
                               title: "Stability Diagnostic",
                               detail: "Online recipe syncing is temporarily paused in this build to pin down the iPad stability issue. The app works fully offline with your existing recipes. This is a temporary test build.")
            ]
        ),
        // ── 0.2.33 — Build 134 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.33",
            buildDate: "Build 134 · June 2026",
            headline: "Diagnostic build",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "stethoscope", color: Color.stockedGold,
                               title: "Stability Diagnostic",
                               detail: "Online recipe syncing is temporarily paused in this build to pin down the iPad stability issue. The app works fully offline with your existing recipes. This is a temporary test build.")
            ]
        ),
        // ── 0.2.32 — Build 133 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.32",
            buildDate: "Build 133 · June 2026",
            headline: "Stability hardening + cleanup",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "lock.shield.fill", color: Color.stockedGreen,
                               title: "Concurrency Hardening",
                               detail: "Data models and helper code are now safe to use across background and main threads, reducing the chance of rare background crashes. Also updated several iOS 26 APIs."),
            ]
        ),
        // ── 0.2.31 — Build 132 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.31",
            buildDate: "Build 132 · June 2026",
            headline: "Build fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hammer.fill", color: Color.stockedCharcoal,
                               title: "Compile Fix",
                               detail: "Corrected an internal build error introduced in the previous update. All the database speed and stability improvements are intact.")
            ]
        ),
        // ── 0.2.30 — Build 131 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.30",
            buildDate: "Build 131 · June 2026",
            headline: "Fixes an iPad freeze + faster, leaner",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "exclamationmark.shield.fill", color: Color.stockedGreen,
                               title: "Fixed an iPad Freeze/Quit",
                               detail: "Resolved an issue where syncing recipes in the background could spike the processor and balloon storage writes, which on iPad could cause the app to be shut down by the system. Recipe syncing is now batched and runs at low priority."),
                ChangelogEntry(icon: "bolt.fill", color: Color.stockedGold,
                               title: "Faster Search & Autocomplete",
                               detail: "Ingredient, brand, and recipe lookups now use indexes instead of scanning the whole list, so search and suggestions feel instant even as your data grows."),
                ChangelogEntry(icon: "tray.full.fill", color: Color.stockedGreen,
                               title: "Smarter Saving",
                               detail: "Bulk changes — like importing a whole receipt — are now saved together in one pass instead of re-saving after every item, which is faster and easier on your battery."),
                ChangelogEntry(icon: "calendar.badge.clock", color: Color.stockedGold,
                               title: "Tidier History",
                               detail: "Older price history and other logs are now trimmed automatically so storage stays small and the app stays quick."),
                ChangelogEntry(icon: "bell.badge.fill", color: Color.stockedGreen,
                               title: "Time-Sensitive Expiry Alerts",
                               detail: "Expiry reminders can now break through Focus and Do Not Disturb as Time Sensitive notifications, so you don't miss food about to go bad.")
            ]
        ),
        // ── 0.2.29 — Build 130 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.29",
            buildDate: "Build 130 · June 2026",
            headline: "Cleaner App Store submission",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal.fill", color: Color.stockedGreen,
                               title: "Submission Warnings Cleared",
                               detail: "Resolved two warnings Apple flagged at upload time by tidying the app's configuration. No change to how the app looks or works.")
            ]
        ),
        // ── 0.2.28 — Build 129 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.28",
            buildDate: "Build 129 · June 2026",
            headline: "More stable, harder to crash",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "shield.lefthalf.filled", color: Color.stockedGreen,
                               title: "Crash Hardening",
                               detail: "A behind-the-scenes reliability pass: the app now guards against the most common causes of unexpected quits, so things stay smooth even with unusual data."),
                ChangelogEntry(icon: "externaldrive.fill.badge.checkmark", color: Color.stockedGold,
                               title: "Safer Saving & Recovery",
                               detail: "Your pantry, grocery list, and recipes now save more safely and keep a backup. If a single saved item is ever damaged, only that item is skipped instead of losing the whole list.")
            ]
        ),
        // ── 0.2.27 — Build 128 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.27",
            buildDate: "Build 128 · June 2026",
            headline: "A big polish pass",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "circle.lefthalf.filled", color: Color.stockedCharcoal,
                               title: "Clearer Cook Buttons",
                               detail: "Cook Now is now the bold primary action and Cook Later sits as a lighter, outlined option — so your eye lands on the main choice. A small line under the button shows what's ready before you tap."),
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Live Counts",
                               detail: "The expiring / to-buy / streak chips gently animate when their numbers change, so you can tell when something updated behind the scenes."),
                ChangelogEntry(icon: "arrow.uturn.backward.circle.fill", color: Color.stockedGreen,
                               title: "Undo Anything Deleted",
                               detail: "Deleting items now shows a quick Undo for a few seconds instead of a scary confirm dialog — and you'll get a small confirmation when the app adds something to your list for you."),
                ChangelogEntry(icon: "hand.draw.fill", color: Color.stockedGold,
                               title: "Move & Drag the Menu Tab",
                               detail: "The left Menu tab can be dragged open (and dragged up or down to reposition it when closed). A one-time hint shows you how."),
                ChangelogEntry(icon: "magnifyingglass", color: Color.stockedCharcoal,
                               title: "Search From the Header",
                               detail: "Recipes now has a search button right in the top bar instead of being buried in the menu."),
                ChangelogEntry(icon: "list.number", color: Color.stockedGreen,
                               title: "Step Markers in Cooking",
                               detail: "Multi-step flows now show which step you're on, so you always know how much is left."),
                ChangelogEntry(icon: "checkmark.shield.fill", color: Color.stockedGold,
                               title: "Friendlier Forms & Clearer Text",
                               detail: "Add Item now points out a missing name as you go, contrast was improved for easier reading (especially in dark mode), recipe lists show placeholders while loading, and more buttons are labeled for VoiceOver.")
            ]
        ),
        // ── 0.2.26 — Build 127 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.26",
            buildDate: "Build 127 · June 2026",
            headline: "Fixes for closing, dragging, and landscape",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "xmark.circle.fill", color: Color.stockedCharcoal,
                               title: "Scan Receipt Closes Properly",
                               detail: "The X and Done buttons on the Scan Receipt screen now close it every time."),
                ChangelogEntry(icon: "hand.draw.fill", color: Color.stockedGold,
                               title: "Drag the Menu Open",
                               detail: "You can now swipe the left Menu tab inward to slide the drawer open — not just tap it. Swipe back to close."),
                ChangelogEntry(icon: "rectangle.landscape.rotate", color: Color.stockedGreen,
                               title: "Cook Buttons in Landscape",
                               detail: "Turn your device sideways and the Cook Now / Cook Later buttons automatically sit side-by-side so they fit the wider screen.")
            ]
        ),
        // ── 0.2.25 — Build 126 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.25",
            buildDate: "Build 126 · June 2026",
            headline: "Tabs remember where you were",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "square.on.square", color: Color.stockedGold,
                               title: "Tabs Keep Their Place",
                               detail: "Switching between Home, Pantry, Recipes, and Grocery now keeps each tab exactly as you left it — your scroll position, search, open sections, and selection all stay put.")
            ]
        ),
        // ── 0.2.19 — Build 120 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.19",
            buildDate: "Build 120 · June 2026",
            headline: "iCloud reconnected",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "icloud.fill", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "iCloud Container Updated",
                               detail: "Backup, restore, and household sharing now point at the app's current iCloud container, fixing cross-device backup and restore.")
            ]
        ),
        // ── 0.2.18 — Build 119 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.18",
            buildDate: "Build 119 · June 2026",
            headline: "Clearer iCloud restore",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "icloud.and.arrow.down.fill", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Better Restore Messages",
                               detail: "When restoring from iCloud, the app now tells you exactly what happened — no connection, a server problem, or simply no backups yet — instead of one vague message.")
            ]
        ),
        // ── 0.2.14 — Build 115 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.14",
            buildDate: "Build 115 · June 2026",
            headline: "Build fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal.fill", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Build Fix",
                               detail: "Fixed an internal text error that was preventing the project from building.")
            ]
        ),
        // ── 0.2.13 — Build 114 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.13",
            buildDate: "Build 114 · June 2026",
            headline: "Cleaner Home & Inventory",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Tidied Up",
                               detail: "Removed a couple of buttons to keep the Home and Inventory screens clean and focused.")
            ]
        ),
        // ── 0.2.12 — Build 113 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.12",
            buildDate: "Build 113 · June 2026",
            headline: "Siri shortcuts that build cleanly",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "mic.fill", color: Color(red: 0.6, green: 0.3, blue: 0.8),
                               title: "Siri Shortcuts",
                               detail: "\"Open my Stocked grocery list\" and \"Start cooking with Stocked\" now open the app to the right place. (Reworked to build reliably across iOS versions.)")
            ]
        ),
        // ── 0.2.11 — Build 112 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.11",
            buildDate: "Build 112 · June 2026",
            headline: "Siri shortcut fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal.fill", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Build Fix",
                               detail: "Fixed a build error in the Siri \"add an item\" shortcut so it compiles correctly.")
            ]
        ),
        // ── 0.2.10 — Build 111 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.2.10",
            buildDate: "Build 111 · June 2026",
            headline: "Stability fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal.fill", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Build Fix",
                               detail: "Fixed two build errors so the move-to-pantry and tuned Surprise Me features compile correctly.")
            ]
        ),
        // ── 0.2.9 — Build 110 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.2.9",
            buildDate: "Build 110 · June 2026",
            headline: "Scanning features restored",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.clockwise.circle.fill", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Receipt Re-Import & Spend Tracking",
                               detail: "Re-added receipt history with re-import and spend tracking, which weren't carried into the latest project export."),
                ChangelogEntry(icon: "text.viewfinder", color: Color.stockedGold,
                               title: "Scan a Handwritten List",
                               detail: "Restored scanning a written or printed shopping list into grocery items, plus faster bulk edits when reviewing a scanned receipt.")
            ]
        ),
        // ── 0.2.8 — Build 109 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.2.8",
            buildDate: "Build 109 · June 2026",
            headline: "A home screen that helps you start",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Fresh Ideas & a Helping Hand",
                               detail: "A refresh button on Home re-rolls your cooking suggestions, and brand-new kitchens get a getting-started card showing the quickest ways to add what you have."),
                ChangelogEntry(icon: "person.2.fill", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Household Activity & Today's Plate",
                               detail: "Your Daily Brief now shows who in your household added what recently, plus a snapshot of the meals you have planned for today."),
                ChangelogEntry(icon: "mic.fill", color: Color(red: 0.6, green: 0.3, blue: 0.8),
                               title: "Siri Shortcuts",
                               detail: "Ask Siri to add an item to your grocery list or to start cooking — hands-free, even when the app is closed.")
            ]
        ),
        // ── 0.2.7 — Build 108 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.2.7",
            buildDate: "Build 108 · June 2026",
            headline: "Scanning that remembers and adds up",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "clock.arrow.circlepath", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Receipt History & Re-Import",
                               detail: "Your scan history now remembers the items on each receipt — tap Re-import to add a past shop straight back to your pantry."),
                ChangelogEntry(icon: "dollarsign.circle.fill", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Spend Tracking",
                               detail: "Stocked now tracks what you spend from scanned receipts, with a per-receipt total and a running total across your scan history."),
                ChangelogEntry(icon: "text.viewfinder", color: Color.stockedGold,
                               title: "Scan a Handwritten List",
                               detail: "Point your camera at a written or printed shopping list and Stocked turns each line into a grocery item. Plus faster bulk edits when reviewing a scanned receipt.")
            ]
        ),
        // ── 0.2.6 — Build 107 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.2.6",
            buildDate: "Build 107 · June 2026",
            headline: "Hands-free-friendly cooking",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "speaker.wave.2.fill", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Read Steps Aloud",
                               detail: "Tap the speaker on any cooking step to have it read out loud — handy when your hands are busy. Tap again to stop."),
                ChangelogEntry(icon: "timer", color: Color.stockedGold,
                               title: "Estimated Timer Total",
                               detail: "Recipes now show the total of their built-in step timers up front, so you know roughly how much hands-on timed cooking to expect.")
            ]
        ),
        // ── 0.2.5 — Build 106 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.2.5",
            buildDate: "Build 106 · June 2026",
            headline: "Cook with what you have",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.2.squarepath", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Substitution Suggestions",
                               detail: "When a recipe needs something you don't have, Stocked now suggests a substitute you already own right under that ingredient — so you can cook without a shopping trip."),
                ChangelogEntry(icon: "minus.circle", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Use an Item by Scanning",
                               detail: "Restored the option to scan a barcode and deduct that item from your pantry as you use it.")
            ]
        ),
        // ── 0.2.4 — Build 105 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.2.4",
            buildDate: "Build 105 · June 2026",
            headline: "Recipes that work with your pantry",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "cart.badge.plus", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Add Missing Ingredients in One Tap",
                               detail: "On the Ready to Cook list, each recipe you can't quite make yet has an \"Add to list\" button that drops its missing ingredients straight onto your grocery list."),
                ChangelogEntry(icon: "heart.fill", color: Color.stockedGold,
                               title: "Favorites & Smarter Substitutions",
                               detail: "Recipes can be marked as favorites, and the app can now suggest ingredient substitutions using only what you already have in stock.")
            ]
        ),
        // ── 0.2.3 — Build 104 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.2.3",
            buildDate: "Build 104 · June 2026",
            headline: "Finish-the-job inventory tools",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "slider.horizontal.3", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Sub-Locations, Categories & Custom Alerts",
                               detail: "When editing an item you can now set a sub-location (Door, Crisper, Top shelf…), a custom category, and the exact low-stock level for that item."),
                ChangelogEntry(icon: "checklist", color: Color.stockedGold,
                               title: "Bulk Quantity Edits",
                               detail: "Select several items and bump their quantities up or down at once — on top of the existing bulk move and delete."),
                ChangelogEntry(icon: "minus.circle", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Use an Item by Scanning",
                               detail: "Scan a product's barcode to deduct it from your pantry as you use it — which also feeds the run-out learning and auto-grocery.")
            ]
        ),
        // ── 0.2.2 — Build 103 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.2.2",
            buildDate: "Build 103 · June 2026",
            headline: "A smarter, tidier pantry",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "magnifyingglass", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Search & Sort Your Inventory",
                               detail: "Search your pantry by name or brand, and sort by use-first (soonest to expire), name, quantity, lowest stock, or most recently bought."),
                ChangelogEntry(icon: "bell.badge", color: Color.stockedGold,
                               title: "Per-Item Low-Stock Levels",
                               detail: "Set how low each item can get before it counts as \"low\" — so a staple you keep lots of and something you buy one of are treated differently."),
                ChangelogEntry(icon: "photo.on.rectangle", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Photos & Export",
                               detail: "Item photos now show as thumbnails in your list, and you can export your whole inventory to a CSV file to share or back up.")
            ]
        ),
        // ── 0.2.1 — Build 102 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.2.1",
            buildDate: "Build 102 · June 2026",
            headline: "Your kitchen now runs itself a little",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.triangle.2.circlepath.circle.fill", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "It Learns When You Run Low",
                               detail: "Stocked now learns how fast you go through each item and predicts when you'll run out — adding those items to your grocery list before you're empty (when auto-add is on)."),
                ChangelogEntry(icon: "calendar.badge.plus", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Build Your List From Your Meal Plan",
                               detail: "One tap on the grocery screen turns your week's planned meals into a shopping list, automatically skipping anything you already have."),
                ChangelogEntry(icon: "tray.and.arrow.down.fill", color: Color.stockedGold,
                               title: "Checked Off → Into Your Pantry",
                               detail: "After shopping, tap \"Move checked → Pantry\" and everything you bought moves into your inventory, merging with what's already there.")
            ]
        ),
        // ── 0.2.0 — Build 101 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.2.0",
            buildDate: "Build 101 · June 2026",
            headline: "Big scanner & inventory upgrade",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "doc.text.viewfinder", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Smarter Receipt Scanning",
                               detail: "Receipts now capture price and quantity, show a summary of what you scanned (counts per zone + total spend), let you scan long receipts across multiple photos, and surface uncertain items first for quick review."),
                ChangelogEntry(icon: "shippingbox.fill", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Inventory That Adds Up",
                               detail: "Re-buying something you already have now increases its quantity instead of creating a duplicate, with unit-aware matching. In a shared household, items remember who added them."),
                ChangelogEntry(icon: "barcode.viewfinder", color: Color.stockedGold,
                               title: "Better Barcode Scanning",
                               detail: "Scanned products are remembered for instant offline re-scans, pack size pre-fills the amount, you can scan a printed expiry date, and if a barcode isn't in the database we now try to identify it automatically."),
            ]
        ),
        // ── 0.1.99 — Build 100 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.1.99",
            buildDate: "Build 100 · June 2026",
            headline: "Stability fix",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "checkmark.seal.fill", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Build Fix",
                               detail: "Resolved a build issue introduced in the previous update. No feature changes.")
            ]
        ),
        // ── 0.1.98 — Build 99 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.98",
            buildDate: "Build 99 · June 2026",
            headline: "Receipt scanner reads the photo",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "camera.viewfinder", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Reads the Whole Receipt Photo",
                               detail: "The scanner now sends the receipt photo to be read directly, far more accurate on faded or oddly-formatted receipts, with on-device and offline fallbacks if there's no connection.")
            ]
        ),
        // ── 0.1.97 — Build 98 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.97",
            buildDate: "Build 98 · June 2026",
            headline: "Receipt scanner keeps store brands",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "tag.fill", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Store Brands Recognized",
                               detail: "Store-brand codes are understood and kept as the brand (e.g. \"GV\" = Great Value), while the item list shows the clean food name.")
            ]
        ),
        // ── 0.1.96 — Build 97 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.96",
            buildDate: "Build 97 · June 2026",
            headline: "Receipt scanner learns your corrections",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "brain.head.profile", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Smarter Receipt Scanning",
                               detail: "When you fix a scanned item's name, the scanner remembers it and uses it to read the same receipt abbreviations correctly next time.")
            ]
        ),
        // ── 0.1.95 — Build 96 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.95",
            buildDate: "Build 96 · June 2026",
            headline: "Secure, faster receipt scanning",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "lock.shield.fill", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Secure Receipt Scanning",
                               detail: "Receipt scanning now runs through a secure service so no private credentials are stored in the app, on a faster model.")
            ]
        ),
        // ── 0.1.94 — Build 95 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.94",
            buildDate: "Build 95 · June 2026",
            headline: "Receipt scanner fixed",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "doc.text.viewfinder", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Receipt Scanner Reads Items Again",
                               detail: "Fixed the receipt scanner falling back to basic parsing and missing or garbling items.")
            ]
        ),
        // ── 0.1.93 — Build 94 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.93",
            buildDate: "Build 94 · June 2026",
            headline: "What's New restored + clearer household transfer",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "Tap to See What's New",
                               detail: "Tapping the build number in Settings opens the What's New list again."),
                ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Clearer Household Transfer",
                               detail: "The transfer screen shows how many items upload and download, and gives an honest message when a join brings no items instead of falsely saying everything is up to date.")
            ]
        ),
        // ── 0.1.92 — Build 93 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.92",
            buildDate: "Build 93 · June 2026",
            headline: "Fixed back & title buttons on every screen",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "hand.tap.fill", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Header Buttons Work Everywhere",
                               detail: "Fixed the back arrow and the \"Stocked.\" title not responding on some screens (like Kitchen Stats, Search, and Scan). The header buttons now reliably work on every screen.")
            ]
        ),
        // ── 0.1.91 — Build 92 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.91",
            buildDate: "Build 92 · June 2026",
            headline: "Simpler Household Sync + correct recipe images",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "person.2.fill", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Household Sync Simplified",
                               detail: "Household Sync now has one clear way to share across Apple IDs (invite link or 8-character code). The old same-account-only code option has been removed to avoid confusion, and Leave Household now cleanly resets your status."),
                ChangelogEntry(icon: "photo.fill", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Correct Recipe Images",
                               detail: "Fixed recipes showing an unrelated photo (e.g. a steak recipe with a picture of samosas). When a true photo of the dish isn't available, the app now shows a clean placeholder instead of a random food image."),
            ]
        ),
        // ── 0.1.81 — Build 82 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.81",
            buildDate: "Build 82 · June 2026",
            headline: "Browse tab, Past Meals in My Collection, Drinks zone, keyboard auto-dismiss, JSON export, drag to calendar",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "safari.fill", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Browse Tab",
                               detail: "The old 'Past Meals' tab is now 'Browse' — a landing page with cards for Online Recipes and Recipe Database. Tap either to search and import recipes."),
                ChangelogEntry(icon: "clock.arrow.circlepath", color: Color.stockedGold,
                               title: "Past Meals in My Collection",
                               detail: "Past Meals now lives as a collapsible section at the bottom of My Collection. Shows meal count badge, expands to the full history list with delete support."),
                ChangelogEntry(icon: "keyboard.chevron.compact.down.fill", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Keyboard Auto-Dismiss (3 sec)",
                               detail: "The keyboard now automatically dismisses after 3 seconds of inactivity. The timer resets on every keystroke. Also dismisses on tap outside or swipe down on scrollable views."),
                ChangelogEntry(icon: "🥤", color: Color(red: 0.28, green: 0.65, blue: 0.95),
                               title: "Drinks Zone",
                               detail: "A new 'Drinks' storage zone covers all beverages — soda, juice, coffee, tea, beer, wine, spirits, milk alternatives, kombucha, and more. The AI receipt scanner and heuristic parser both route drinks correctly instead of putting them in Staples."),
                ChangelogEntry(icon: "doc.text.fill", color: Color(red: 0.3, green: 0.6, blue: 0.9),
                               title: "JSON Export",
                               detail: "Kitchen Transfer now offers two export formats: .stocked (native, full fidelity) and .json (open standard, compatible with any app or spreadsheet). Both can be re-imported by Stocked."),
                ChangelogEntry(icon: "hand.draw.fill", color: Color.stockedGold,
                               title: "Drag Inventory Item to Meal Calendar",
                               detail: "In the Meal Planner calendar view, long-press any inventory item row in Inventory and drag it onto a calendar day cell. It's added as a planned Dinner for that day. The item name becomes the meal title."),
            ]
        ),
        // ── 0.1.80 — Build 81 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.80",
            buildDate: "Build 81 · June 2026",
            headline: "Full theme system rebuild — Classic preset, unified color channels, keyboard dismiss fixed",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "paintpalette.fill", color: Color.stockedBg,
                               title: "Classic Preset",
                               detail: "The original Stocked. warm tan look is now a named preset called 'Classic', listed first in Settings → Appearance → Theme Presets. It's the default on fresh installs and after sign-out."),
                ChangelogEntry(icon: "switch.2", color: Color.stockedGold,
                               title: "Unified Color Channel System",
                               detail: "All six color channels (background, accent, button, text, card, tab) are now the single source of truth for every color in the app. Selecting any preset writes all six channels immediately. No more dual-path where some views used hardcoded values and others used the channels."),
                ChangelogEntry(icon: "app.fill", color: Color(red: 0.08, green: 0.08, blue: 0.10),
                               title: "Themes Apply Everywhere",
                               detail: "Preset colors now propagate to every sheet, modal, tab bar pill, tab bar background, root window background, and UIKit window. Previously 33 files bypassed the theme system with hardcoded colors — all fixed."),
                ChangelogEntry(icon: "keyboard.chevron.compact.down", color: Color(red: 0.38, green: 0.78, blue: 0.42),
                               title: "Keyboard Dismiss Fixed",
                               detail: "Tapping anywhere outside a text field now dismisses the keyboard across the entire app. Previously, the dismiss gesture competed with and blocked TextFields on the same view. Fixed using simultaneousGesture on a clear layer, which runs alongside child recognizers instead of blocking them."),
                ChangelogEntry(icon: "rectangle.stack", color: Color(red: 0.06, green: 0.10, blue: 0.20),
                               title: "Keyboard No Longer Pushes Content",
                               detail: "On fixed-height views (Recipes tab, etc.), the keyboard now overlays on top of content instead of resizing the layout and pushing items off screen."),
                ChangelogEntry(icon: "safari", color: Color.stockedGold,
                               title: "Browse Online Button Restored",
                               detail: "The 'Browse Online' button in My Collection and the 'Browse Online' CTA on the empty pantry state both correctly open the online recipe browser sheet again."),
            ]
        ),
        // ── 0.1.79 — Build 80 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.79",
            buildDate: "Build 80 · June 2026",
            headline: "Receipt multi-scan, archive, store detection, screenshot import; appearance presets, haptics, household sync, mid-cook subs",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "doc.text.viewfinder", color: Color.stockedGold,
                               title: "Multi-Receipt Session",
                               detail: "Scan multiple receipts back-to-back without leaving. The done screen shows a running total and offers 'Scan Another Receipt'. Session totals are tracked."),
                ChangelogEntry(icon: "clock.arrow.circlepath", color: Color(red: 0.35, green: 0.55, blue: 0.95),
                               title: "Receipt Archive",
                               detail: "Every completed scan is saved to a history log with date, store, and item count. Tap the clock icon in the scanner header to browse past scans (last 30)."),
                ChangelogEntry(icon: "storefront", color: Color(red: 0.3, green: 0.7, blue: 0.5),
                               title: "Store Name Detection",
                               detail: "The scanner reads the first lines of OCR text and matches against 20 known grocery chains. When found, the store name appears under the header and is saved to the archive."),
                ChangelogEntry(icon: "photo.on.rectangle", color: Color(red: 0.6, green: 0.3, blue: 0.9),
                               title: "Import Receipt Screenshot",
                               detail: "A new 'Import Screenshot' button on the instructions screen opens the photo library. Select any receipt image — digital orders, email confirmations, screenshot — and the same AI parse runs on it."),
                ChangelogEntry(icon: "arrow.up.arrow.down.circle", color: Color.orange,
                               title: "Bulk Zone Override",
                               detail: "On the review screen, a Bulk Zone menu lets you move all checked items to Fridge, Freezer, Pantry, or Staples in one tap. Useful when a full scan lands everything in Pantry by default."),
                ChangelogEntry(icon: "doc.on.doc", color: Color(red: 0.8, green: 0.4, blue: 0.2),
                               title: "Duplicate Suppression",
                               detail: "When adding items to the pantry, any item whose name fuzzy-matches an existing inventory entry is silently skipped. The count shown reflects only genuinely new additions."),
                ChangelogEntry(icon: "paintpalette.fill", color: Color(red: 0.35, green: 0.55, blue: 0.95),
                               title: "Appearance Presets",
                               detail: "Settings → Appearance now has six named presets: Custom, Midnight, Sand, Forest, Ocean, and Rose. Each sets dark/light mode and a coordinated accent color in one tap."),
                ChangelogEntry(icon: "waveform.path", color: Color(red: 0.4, green: 0.7, blue: 0.9),
                               title: "Haptic Intensity",
                               detail: "Settings → Appearance → Haptics lets you choose Off, Light, Medium, or Strong. The selection fires immediately as a preview."),
                ChangelogEntry(icon: "fork.knife.circle", color: Color.stockedGold,
                               title: "Default Recipe View",
                               detail: "Settings → Appearance → Default Recipe View sets which tab opens first when you tap Recipes: Ready to Cook, My Collection, Past Meals, or For You."),
                ChangelogEntry(icon: "app.gift.fill", color: Color(red: 0.6, green: 0.3, blue: 0.9),
                               title: "App Icon Variants",
                               detail: "Settings → Appearance → App Icon offers four icon options: Classic, Midnight, Light, and Minimal. Uses UIApplication.setAlternateIconName — requires alternate icons added in Xcode assets."),
                ChangelogEntry(icon: "clock.arrow.2.circlepath", color: Color(red: 0.27, green: 0.56, blue: 0.87),
                               title: "Auto-Backup Frequency",
                               detail: "Settings → Kitchen → Auto-Backup lets you choose Manual, Daily, or Weekly iCloud backup frequency."),
                ChangelogEntry(icon: "person.2.fill", color: Color(red: 0.35, green: 0.55, blue: 0.95),
                               title: "Household Sync",
                               detail: "Settings → Kitchen → Household Sync. Each device shows a stable 6-digit code. Enter another device's code to join their household. Code is written to iCloud KV store for cross-device sync."),
                ChangelogEntry(icon: "arrow.left.arrow.right", color: Color.stockedGold,
                               title: "Mid-Cook Substitutions",
                               detail: "In the cooking flow, any ingredient with a known substitute shows a 'Sub' pill. Tap it to get a full substitution sheet — with in-stock indicator — without leaving the step list."),
            ]
        ),
        // ── 0.1.78 — Build 79 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.78",
            buildDate: "Build 79 · June 2026",
            headline: "Photos, pairings, cook history, nutrition, notes, grocery push, share list, custom subs, abbreviation auto-learn",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "camera.fill", color: Color(red: 0.35, green: 0.55, blue: 0.95),
                               title: "Photo per Inventory Item",
                               detail: "Tap any item in the Inventory to open the edit sheet. A new photo row lets you pick an image from your library. Stored locally, compressed to ~300KB."),
                ChangelogEntry(icon: "doc.on.doc", color: Color(red: 0.8, green: 0.4, blue: 0.2),
                               title: "Duplicate Detection",
                               detail: "Adding an item that fuzzy-matches an existing inventory entry now shows an alert: 'Already in Pantry — Add Anyway or Cancel.'"),
                ChangelogEntry(icon: "link.circle", color: Color(red: 0.3, green: 0.7, blue: 0.5),
                               title: "Ingredient Pairings",
                               detail: "Long-press any inventory item to see 'Ingredient Pairings' in the context menu. Shows what pairs well and highlights what you already have in stock."),
                ChangelogEntry(icon: "clock.arrow.circlepath", color: Color.stockedGold,
                               title: "Cook History on Recipes",
                               detail: "Each saved recipe now shows 'Made 3×, last May 12' below the title. Cook count and date update automatically when you tap Start Cooking."),
                ChangelogEntry(icon: "chart.bar", color: Color(red: 0.6, green: 0.3, blue: 0.9),
                               title: "Nutritional Summary",
                               detail: "Recipe detail now shows a Calories / Protein / Carbs / Fat bar when ingredient nutrition data is present. Values scale with the serving adjuster."),
                ChangelogEntry(icon: "note.text", color: Color(red: 0.4, green: 0.6, blue: 0.9),
                               title: "Recipe Notes",
                               detail: "A Notes section on every recipe detail page. Tap Edit to add freeform notes — modifications, substitutions, what you'd change next time."),
                ChangelogEntry(icon: "cart.badge.plus", color: Color(red: 0.2, green: 0.7, blue: 0.4),
                               title: "Linked Grocery Push",
                               detail: "Tap 'Add Missing to List' from any recipe's ingredient section to push all missing ingredients directly to the Grocery List, grouped under the recipe name."),
                ChangelogEntry(icon: "arrow.triangle.merge", color: Color.orange,
                               title: "Duplicate Recipe Merge",
                               detail: "The My Collection tab now detects near-identical recipes and shows a merge badge. Tap it to review the pair and keep one or both."),
                ChangelogEntry(icon: "square.and.arrow.up", color: Color(red: 0.35, green: 0.55, blue: 0.95),
                               title: "Share Grocery List",
                               detail: "A share button in the Grocery List action bar exports all unchecked items as plain text via the system share sheet — text, Messages, Mail, etc."),
                ChangelogEntry(icon: "arrow.left.arrow.right", color: Color.stockedGold,
                               title: "Custom Substitutions",
                               detail: "Databases → Substitutions now has a + button. Add your own ingredient substitutions. They appear at the top of the list with a Custom badge and can be deleted."),
                ChangelogEntry(icon: "sparkles", color: Color(red: 0.8, green: 0.6, blue: 0.2),
                               title: "Abbreviation Auto-Learn",
                               detail: "When you manually correct a receipt item that wasn't in the abbreviation database, a prompt appears inline: 'Save CHKN BRS → Chicken Breast as abbreviation?' One tap saves it permanently."),
            ]
        ),
        // ── 0.1.77 — Build 78 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.77",
            buildDate: "Build 78 · June 2026",
            headline: "Adaptive layout — all iPhone screen sizes, iPhone 16 Pro baseline",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "iphone", color: Color(red: 0.35, green: 0.55, blue: 0.95),
                               title: "Adaptive Layout Engine",
                               detail: "SizeSystem.swift fully rewritten with iPhone 16 Pro (393pt) as the canonical baseline. All screen sizes — SE, standard, Pro Max — now scale proportionally from that reference point."),
                ChangelogEntry(icon: "sidebar.left", color: Color.stockedCharcoal,
                               title: "Adaptive Drawer & Tab Bar",
                               detail: "Left drawer width and tab bar height now pull from SS tokens per device: SE gets a 290pt drawer, 16 Pro stays 320pt, Pro Max gets 340pt. Tab bar scales from 60pt (SE) to 72pt (Pro Max)."),
                ChangelogEntry(icon: "arrow.up.left.and.arrow.down.right", color: Color.stockedGold,
                               title: "Cook Buttons — Device-Aware Defaults",
                               detail: "Cook button default size is now set at launch based on the actual screen width. SE: 180pt, standard Pro: 220pt, Pro Max: 240pt. GeometryReader removed from HomeView."),
                ChangelogEntry(icon: "rectangle.topthird.inset.filled", color: Color(red: 0.3, green: 0.7, blue: 0.5),
                               title: "Header Safe Area",
                               detail: "StockedShell safe area fallback updated to 59pt — the correct Dynamic Island inset for iPhone 16 Pro. Was previously 47pt which clipped the header on newer devices."),
                ChangelogEntry(icon: "textformat.size", color: Color(red: 0.6, green: 0.3, blue: 0.9),
                               title: "SS Token Library",
                               detail: "Full set of adaptive tokens now available: padH, cardPad, padV, gap, tabBarH, drawerW, cookBtnSz, radiusSm/Md/Lg, iconMd/Sm, titleLg/Md/Sm, body, caption. Use SS.token.value(for: device) anywhere."),
            ]
        ),
        // ── 0.1.76 — Build 77 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.76",
            buildDate: "Build 77 · June 2026",
            headline: "Databases hub, For You, Ready to Cook hierarchy, Substitutions, Receipt abbreviations",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "cylinder.split.1x2", color: Color(red: 0.35, green: 0.55, blue: 0.95),
                               title: "Databases Hub",
                               detail: "A new Databases section is now accessible from the left drawer and iPad sidebar. It contains four tabs — Substitutions, Abbreviations, Ingredients, and Tips — each searchable and editable."),
                ChangelogEntry(icon: "sparkles", color: Color.stockedGold,
                               title: "For You — Premium Teaser",
                               detail: "A fourth tab in the Recipe Hub previews the upcoming For You feature — personalized AI recipes built from your taste profile and pantry. Tapping any card opens a Coming Soon / Premium sheet."),
                ChangelogEntry(icon: "chart.bar.fill", color: Color(red: 0.3, green: 0.7, blue: 0.5),
                               title: "Ready to Cook — Ingredient Hierarchy",
                               detail: "Ready to Cook now shows every recipe sorted by how many ingredients you already have, not just fully-matched ones. Each card shows a progress bar, a Ready Now badge (gold) or Missing N badge, and the names of what you're short."),
                ChangelogEntry(icon: "arrow.left.arrow.right", color: .orange,
                               title: "Ingredient Substitutions",
                               detail: "Recipe details now include a Substitutions section sourced from the Food Network guide — 75 ingredients with alternatives and ratios. Ingredients that have a known substitute show a Sub ↓ link inline. Grocery list items show a Sub available hint. Tapping a Sub link auto-highlights that ingredient's entry."),
                ChangelogEntry(icon: "textformat.abc", color: Color(red: 0.6, green: 0.3, blue: 0.9),
                               title: "Receipt Abbreviation Catalog",
                               detail: "The receipt scanner now checks a built-in abbreviation database (190+ entries) before parsing. Correcting a scanned item inline saves that mapping so the same abbreviation resolves automatically next time. The full catalog is viewable and editable in Databases → Abbreviations."),
                ChangelogEntry(icon: "lightbulb.fill", color: Color(red: 0.95, green: 0.7, blue: 0.2),
                               title: "Cooking Tips",
                               detail: "51 tips across 8 categories (General Cooking, Baking, Reading Recipes, Substitution Tips, Measurements, Food Safety, Knife & Prep, Storage) are now baked into the app. Three random tips appear at the bottom of every recipe detail. The full catalog is browsable in Databases → Tips."),
                ChangelogEntry(icon: "info.circle.fill", color: Color.stockedCharcoal,
                               title: "Build Info Footer",
                               detail: "The build number and version are now displayed below Settings in the drawer — always in sync with the internal build counter. Updates automatically with every new build."),
                ChangelogEntry(icon: "server.rack", color: Color(red: 0.2, green: 0.6, blue: 0.8),
                               title: "Unified Database Engine",
                               detail: "All database logic (substitutions, abbreviations, tips) is consolidated into a single StockedDatabase singleton. All existing call sites continue to work via compatibility shims. Dead code removed; no regressions."),
            ]
        ),
        // ── 0.1.62 — Build 63 (June 2026) ───────────────────────────────────────
        ChangelogVersion(
            version: "0.1.62",
            buildDate: "Build 63 · June 2026",
            headline: "Cook Flow — step timers, ingredient scaling, checklist, finish-to-deduct",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "timer", color: Color.stockedGold,
                               title: "Step Timers",
                               detail: "Every step with a time mention now shows a live countdown. Tap ▶ to start. Multiple timers run at once — pasta boiling and vegetables roasting simultaneously. A notification fires when each timer ends."),
                ChangelogEntry(icon: "person.2.fill", color: Color(red: 0.3, green: 0.7, blue: 0.5),
                               title: "Ingredient Scaling",
                               detail: "Serving count now scales every ingredient amount. Tap − or + next to the serving count on the recipe overview to adjust — quantities update instantly throughout the ingredient list."),
                ChangelogEntry(icon: "checklist", color: Color(red: 0.35, green: 0.55, blue: 0.95),
                               title: "Ingredients Checklist While Cooking",
                               detail: "An ingredient checklist is now pinned above the step list during cooking. Tap any ingredient to mark it as prepped. Shows X/Y prepped count in the header."),
                ChangelogEntry(icon: "cart.badge.minus", color: .orange,
                               title: "Deduct on Finish — Not on Start",
                               detail: "Inventory is no longer deducted the moment you tap Start Cooking. Instead, when you finish, you see each ingredient and can uncheck anything you didn't use before confirming deduction."),
                ChangelogEntry(icon: "xmark.circle", color: Color.stockedCharcoal,
                               title: "Cancel Cook — No Inventory Change",
                               detail: "Leaving the cook flow now asks for confirmation. If you cancel, nothing is deducted from your pantry. You can restart the recipe any time."),
            ]
        ),
        // ── 0.1.7.0 — Build 62 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.1.7.0",
            buildDate: "Build 62 · June 2026",
            headline: "Full code audit — API auth fix, entitlements, storage & image clean-up",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "network", color: Color.stockedGreen,
                               title: "Receipt Scanner — AI Now Works",
                               detail: "Fixed a missing authentication header that was silently causing every receipt scan to fall back to the basic parser. Claude now correctly reads and categorises your grocery items."),
                ChangelogEntry(icon: "checkmark.shield.fill", color: Color(red: 0.2, green: 0.6, blue: 0.4),
                               title: "Entitlements Cleaned Up",
                               detail: "Removed unused HealthKit entitlement (which could cause App Store rejection) and corrected the push-notification environment to production so alerts work on TestFlight and the App Store."),
                ChangelogEntry(icon: "photo.slash", color: Color.stockedCharcoal,
                               title: "Image Fallback — Terms Compliance",
                               detail: "Removed the deprecated Unsplash Source API (shut down 2022; also required photo attribution the app wasn't providing). Food items now fall back to the crisp emoji placeholder, which works offline and looks great."),
                ChangelogEntry(icon: "arrow.triangle.2.circlepath", color: Color.stockedGold,
                               title: "Storage Writes Optimised",
                               detail: "Removed legacy synchronize() calls that were forcing unnecessary disk I/O on every inventory or grocery change. The OS now handles flushing at the right moment — smoother scrolling and checking items off lists."),
                ChangelogEntry(icon: "fork.knife", color: .orange,
                               title: "Ready-to-Cook Recipes — Live",
                               detail: "The 'recipes you can cook right now' logic was a stub returning nothing. It now checks your actual inventory and returns every saved recipe where all ingredients are in stock."),
                ChangelogEntry(icon: "hammer.fill", color: Color(red: 0.4, green: 0.4, blue: 0.9),
                               title: "xcconfig — API Key Slot Added",
                               detail: "All three build configs (Debug, Staging, Release) now have a CLAUDE_API_KEY slot wired through BuildConfig.swift. Set your key once in the xcconfig; it's injected at build time and never hardcoded."),
            ]
        ),
        // ── 0.1.6.0 — Build 61 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.1.6.0",
            buildDate: "Build 61 · June 2026",
            headline: "Dark mode fixes — ServingSize, CookingFlow & MainTab",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "person.fill", color: Color.stockedGold,
                               title: "Serving Size — Dark Mode",
                               detail: "Icon, question text, serving counter circle, number buttons, hint label, and Continue button all now render correctly in dark mode using explicit dark/light color branches."),
                ChangelogEntry(icon: "flame.fill", color: .orange,
                               title: "Cooking Flow — Missing Items Panel",
                               detail: "The missing-items warning card now uses themeTextColor throughout and a clean appButton background — no more dark-mode color leaks. Step labels also fixed to use themeTextColor."),
                ChangelogEntry(icon: "doc.text.fill", color: Color.stockedCharcoal,
                               title: "Main Tab — Preferences & Build Label",
                               detail: "Removed redundant build-number row from the settings list (it now lives in the Changelog screen). Preferences shortcut simplified."),
            ]
        ),
        // ── 0.1.5.9 — Build 60 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.1.5.9",
            buildDate: "Build 60 · June 2026",
            headline: "Dark mode audit — all views verified against design system",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "moon.fill", color: Color.stockedCharcoal,
                               title: "Dark Mode Compliance",
                               detail: "Full audit against the DO_NOT_TOUCH design system source. Every view confirmed to use themeTextColor, appBg(isDarkMode), darkSurface, and appButton(isDarkMode) — no hardcoded light-only colors slip through in dark mode."),
                ChangelogEntry(icon: "checkmark.seal.fill", color: Color.stockedGreen,
                               title: "Calendar Day Panel — Dark Mode",
                               detail: "The new calendar day detail panel uses darkSurface background in dark mode, matching the same card pattern used across all other views."),
            ]
        ),
        // ── 0.1.5.8 — Build 59 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.1.5.8",
            buildDate: "Build 59 · June 2026",
            headline: "Meal Planner calendar — tap a day to see meals, prep, and cook",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "calendar", color: Color.stockedGold,
                               title: "Calendar Day Detail",
                               detail: "Tap any day in the calendar to see the meals planned for that day. Future days show a 'Scheduled' badge so you know what's coming up."),
                ChangelogEntry(icon: "fork.knife.circle.fill", color: .orange,
                               title: "Prep & Cook from Calendar",
                               detail: "Each meal card in the calendar day panel now has full Prep Now and Cook Now buttons — no need to switch to list view."),
                ChangelogEntry(icon: "list.bullet.rectangle", color: Color(red:0.35,green:0.55,blue:0.95),
                               title: "Toggle Icon Fixed",
                               detail: "The view-toggle button in the top-right now shows the correct icon for where you're going: 'Calendar' when in list view, 'List' when in calendar view."),
                ChangelogEntry(icon: "plus.circle.fill", color: Color.stockedGreen,
                               title: "Meals Sync Across Views",
                               detail: "Meals added via the calendar quick-add immediately appear in the list view and vice versa — one shared plan, two ways to see it."),
            ]
        ),
        // ── 0.1.5.7 — Build 58 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.1.5.7",
            buildDate: "Build 58 · June 2026",
            headline: "Pinned headers — top controls stay anchored while you scroll",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "pin.fill", color: Color.stockedGold,
                               title: "Inventory — Pinned Header",
                               detail: "Scan Barcode, Scan Receipt, and zone tabs (All, Fridge, Freezer…) stay fixed at the top. Only the item list scrolls."),
                ChangelogEntry(icon: "pin.fill", color: .orange,
                               title: "Recipes — Pinned Header",
                               detail: "Greeting, search bar, and tab pills (Cook Now, My Collection…) stay anchored. Tab content scrolls independently."),
                ChangelogEntry(icon: "pin.fill", color: Color(red:0.35,green:0.55,blue:0.95),
                               title: "Grocery — Pinned Header",
                               detail: "Shopping At store badge and the search/add bar stay locked in place. The grocery list scrolls below them."),
            ]
        ),
        // ── 0.1.5.6 — Build 57 (June 2026) ──────────────────────────────────────
        ChangelogVersion(
            version: "0.1.5.6",
            buildDate: "Build 57 · June 2026",
            headline: "Daily Brief fully wired — all actions lead where intended",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "calendar.badge.checkmark",  color: Color.stockedGold,
                               title: "Daily Brief — Preferences",
                               detail: "Tapping Preferences in the Daily Brief now opens the Settings drawer correctly."),
                ChangelogEntry(icon: "fork.knife",                color: .orange,
                               title: "Daily Brief — Build Meal",
                               detail: "Add to Meal and Build Meal buttons now open the Meal Builder instead of the Shopping List."),
                ChangelogEntry(icon: "clock.badge.exclamationmark", color: .orange,
                               title: "Expiring & Low Stock Detail",
                               detail: "Build Meal in the Expiring Soon and Low Stock detail pages now launches the Meal Builder."),
                ChangelogEntry(icon: "hammer.fill",               color: Color(red:0.35,green:0.55,blue:0.95),
                               title: "Build Number in Settings",
                               detail: "Settings now shows the current build number, updated automatically with each release."),
            ]
        ),
        // ── 1.0.0 — Anchor Build 1 (May 2026) ─────────────────────────────────
        ChangelogVersion(
            version: "1.0.0",
            buildDate: "Anchor Build 1 · May 2026",
            headline: "First confirmed anchor — Build 1 🎉",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sidebar.left",               color: Color.stockedGold,                    title: "Menu Edge Tab",           detail: "The left-edge Menu tab slides in sync with the drawer. Fully adjustable height and width from Settings."),
                ChangelogEntry(icon: "text.alignleft",             color: Color(red:0.6,green:0.3,blue:0.8),    title: "Font Placement Control",  detail: "New vertical and horizontal font offset sliders in Settings → Appearance. Reset button included."),
                ChangelogEntry(icon: "chevron.down.circle",        color: Color.stockedCharcoal,                title: "Stocked. Header Brief",   detail: "Tapping Stocked. on any tab opens the Daily Brief. Header coach mark dims the screen and uses white text on charcoal."),
                ChangelogEntry(icon: "clock.badge.exclamationmark",color: Color.stockedGold,                    title: "Daily Brief — Expiry",    detail: "Expiring Soon and Low Stock sections now appear in the Daily Brief with Add to List and Build Meal actions."),
                ChangelogEntry(icon: "checklist",                  color: Color(red:0.3,green:0.7,blue:0.5),    title: "Settings Dropdowns",      detail: "All settings sections (Account, Appearance, Store, Kitchen, Data) collapse and expand via DisclosureGroup."),
                ChangelogEntry(icon: "person.crop.circle.badge.checkmark", color: Color(red:0.27,green:0.56,blue:0.87), title: "Chef Icon Prompt", detail: "First-run prompt dims the quiz background and highlights your avatar so you know it's customisable."),
                ChangelogEntry(icon: "pencil.circle.fill",         color: Color(red:0.3,green:0.7,blue:0.5),    title: "Edit Preferences",        detail: "Change diet, cuisines, skill level, and meals per week individually — no need to retake the full quiz."),
                ChangelogEntry(icon: "frying.pan.fill",            color: Color(red:0.9,green:0.4,blue:0.2),    title: "Cooking Equipment Quiz",  detail: "New quiz step asks which appliances you own. Recipes that need equipment you don't have are filtered out."),
                ChangelogEntry(icon: "magnifyingglass",            color: Color.stockedGold,                    title: "Predictive Recipe Search", detail: "Online recipe search now shows predictive chips as you type, synced to the local RecipeDatabase."),
                ChangelogEntry(icon: "cart.badge.plus",            color: Color(red:0.6,green:0.3,blue:0.8),    title: "Grocery Quantity",        detail: "Each grocery list item now has a + / − stepper. Quantities update in real time."),
                ChangelogEntry(icon: "plus.circle.fill",           color: Color.stockedCharcoal,                title: "Inventory + Menu",        detail: "The Inventory tab has a single + button that reveals Add Item, Scan Barcode, and Scan Receipt options."),
                ChangelogEntry(icon: "circle.dotted.circle",       color: Color.stockedGold,                    title: "Inventory Indicators",    detail: "Protein and vegetable chips in Cook Now show a gold dot when that item is in your current inventory."),
                ChangelogEntry(icon: "star.fill",                  color: Color.stockedGold,                    title: "For You (Coming Soon)",   detail: "A premium For You category is reserved in the Recipe tab — personalised AI recipes based on your profile."),
                ChangelogEntry(icon: "database.fill",              color: Color(red:0.27,green:0.56,blue:0.87), title: "Database Sync",           detail: "RecipeDatabase, WebRecipeCatalogue, and OfflineRecipeCache sync automatically at launch and after any recipe save."),
                ChangelogEntry(icon: "fork.knife.circle.fill",     color: Color.stockedGold,                    title: "14 Seed Recipes",         detail: "14 Taste of Home recipes pre-loaded at first launch including Chicken Casserole, Beef Stew, Shepherd\'s Pie, and more."),
                ChangelogEntry(icon: "globe",                      color: Color(red:0.6,green:0.3,blue:0.8),    title: "280 Recipe URLs",         detail: "280 curated Taste of Home recipe URLs pre-queued for background import so your recipe library is rich from day one."),
            ]
        ),

        // ── 0.1.1 — Build 1 Patch 1 (May 2026) ─────────────────────────────────
        ChangelogVersion(
            version: "0.1.1",
            buildDate: "Build 1 Patch 1 · May 2026",
            headline: "Smarter editing, connected databases, everything talks 🔗",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "arrow.triangle.2.circlepath",   color: Color.stockedGold,                    title: "All Databases Sync",      detail: "Your inventory, grocery list, saved recipes, web recipes, and Taste of Home library all update each other instantly. Add something once — it shows everywhere it's relevant."),
                ChangelogEntry(icon: "pencil.circle.fill",             color: Color(red:0.3,green:0.7,blue:0.5),    title: "Tap Any Name to Edit",    detail: "Tap the name of any pantry item, grocery item, recipe, or ingredient to edit it right there. No extra screens, no extra taps."),
                ChangelogEntry(icon: "text.magnifyingglass",           color: Color(red:0.27,green:0.56,blue:0.87), title: "Food Suggestions Everywhere", detail: "Every field where you type a food item now shows matching suggestions from hundreds of common ingredients. Tap a chip to fill the field."),
                ChangelogEntry(icon: "fork.knife.circle.fill",         color: Color.stockedGold,                    title: "Recipe Suggestions Everywhere", detail: "Every field where you type a recipe title pulls in matching recipes from your collection, Taste of Home, and online sources. Tap a suggestion to auto-fill the whole recipe."),
                ChangelogEntry(icon: "clock.badge.exclamationmark",    color: .orange,                              title: "Expiring Soon Detail Page",detail: "The Daily Brief Expiring Soon section now has a full detail page. Items are grouped by where they're stored, with one-tap add to grocery list or build a meal."),
                ChangelogEntry(icon: "chart.bar.fill",                 color: Color.stockedGold,                    title: "Low Stock Detail Page",   detail: "Same for Low Stock — tap See all low stock items for a grouped view of everything running out, with quick restock and meal-building options."),
                ChangelogEntry(icon: "circle.dotted.circle",           color: Color(red:0.3,green:0.7,blue:0.5),    title: "Pantry Indicators in Cook Now", detail: "When choosing a protein or vegetable in Cook Now → Foods, items already in your pantry show a gold In pantry badge. Dimmed items aren't stocked — but you can still pick them."),
                ChangelogEntry(icon: "person.crop.circle.badge.checkmark", color: Color(red:0.6,green:0.3,blue:0.8), title: "Chef Icon Spotlight",   detail: "At the start of the quiz, the screen dims and a gold ring highlights your chef icon so you know you can tap it to pick your avatar."),
                ChangelogEntry(icon: "rectangle.and.arrow.up.right.and.arrow.down.left", color: Color.stockedCharcoal, title: "Header Always Visible in Prompts", detail: "When the Kitchen at a Glance tip appears, the Stocked. header stays fully visible above the dim. Text is now pure white for easy reading."),
                ChangelogEntry(icon: "xmark.circle",                   color: Color(red:0.27,green:0.56,blue:0.87), title: "Tap Outside Stores to Close", detail: "After tapping Nearby Stores in the Grocery tab, tapping anywhere outside the store list closes it. An X button is also shown at the top of the list."),
            ]
        ),

        // ── 0.1.0 — Pre-anchor reference ────────────────────────────────────
        ChangelogVersion(
            version: "0.1.0",
            buildDate: "Pre-anchor · May 2026",
            headline: "Pre-anchor reference build",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "sidebar.left",         color: Color.stockedGold,                    title: "Unified Navigation",      detail: "iPad sidebar and iPhone drawer now show the same navigation, quick actions, and settings. No separate bolt button."),
                ChangelogEntry(icon: "slider.horizontal.3",  color: Color(red:0.6,green:0.3,blue:0.8),    title: "Settings in Drawer",      detail: "All app settings — theme, colours, fonts, store, notifications — are now inside the navigation drawer. No separate settings panel."),
                ChangelogEntry(icon: "person.crop.circle.badge.checkmark", color: Color.stockedCharcoal,  title: "Card-Style Onboarding",   detail: "The kitchen setup quiz is now a swipeable card — same size on all devices. Tap your avatar to personalise it."),
                ChangelogEntry(icon: "rectangle.stack",      color: Color(red:0.27,green:0.56,blue:0.87), title: "Consistent Sheets",       detail: "Every popup, sheet and modal now uses the same tan background, handle, and serif header for a unified look."),
                ChangelogEntry(icon: "plus.circle.fill",     color: Color(red:0.3,green:0.7,blue:0.5),    title: "3-Step Add Item",         detail: "Adding pantry items is now a guided 3-step flow: basic info → size details → expiry. Browse the ingredient database from step 1."),
                ChangelogEntry(icon: "barcode.viewfinder",   color: Color(red:0.9,green:0.4,blue:0.2),    title: "Bulk Barcode Scan",       detail: "Choose single or bulk scan mode when opening the scanner. Bulk mode keeps scanning after each item — perfect for stocking up."),
                ChangelogEntry(icon: "globe",                color: Color.stockedGold,                    title: "20 Recipe Sources",       detail: "Recipes can now be imported from 20 trusted sites including Serious Eats, Bon Appétit, AllRecipes, and more — with full steps, times, and images."),
                ChangelogEntry(icon: "brain",                color: Color(red:0.6,green:0.3,blue:0.8),    title: "Smarter AI Recipes",      detail: "The Surprise Me engine now uses on-device NaturalLanguage to understand your pantry and cooking style before generating recipes."),
                ChangelogEntry(icon: "icloud.fill",          color: Color(red:0.27,green:0.56,blue:0.87), title: "Full Data Clear",         detail: "Clearing app data now wipes everything: pantry, grocery list, meals, recipes, settings, iCloud backup, and sign-in session."),
            ]
        ),


        // ── 0.0.1 — Pre-release reference ────────────────────────────────────
        ChangelogVersion(
            version: "0.0.1",
            buildDate: "Pre-release · 2026",
            headline: "Internal reference build",
            isLatest: false,
            entries: [
                ChangelogEntry(icon: "house.fill",            color: Color.stockedGold,           title: "Smart Home Screen",           detail: "See exactly what meals you can make right now, what's running low, and today's quick brief — all in one glance."),
                ChangelogEntry(icon: "refrigerator.fill",     color: Color(red:0.27,green:0.56,blue:0.87), title: "Pantry & Fridge Inventory", detail: "Track everything in your kitchen with zones (Fridge, Freezer, Pantry, Spices). Add items by barcode scan, receipt scan, or manually."),
                ChangelogEntry(icon: "cart.fill",             color: Color(red:0.3,green:0.7,blue:0.5),   title: "Smart Grocery List",      detail: "Items you run low on get added automatically. Check them off while you shop — the app tracks what you've bought."),
                ChangelogEntry(icon: "fork.knife",            color: Color.stockedCharcoal,       title: "Recipe Vault",                detail: "Save, import, and cook from your own recipe collection. Import recipes straight from any website URL."),
                ChangelogEntry(icon: "sparkles",              color: Color(red:0.6,green:0.3,blue:0.8),   title: "AI Recipe Generator",     detail: "Tell the app what you're in the mood for — it generates a custom recipe using what you already have."),
                ChangelogEntry(icon: "camera.viewfinder",     color: Color(red:0.9,green:0.4,blue:0.2),   title: "Receipt Scanner",         detail: "Photograph your grocery receipt and Stocked automatically adds everything to your pantry."),
                ChangelogEntry(icon: "calendar",              color: Color(red:0.35,green:0.55,blue:0.95), title: "Meal Planner",           detail: "Plan your week of meals in advance and let Stocked build your grocery list from the plan automatically."),
                ChangelogEntry(icon: "person.fill.questionmark", color: Color.stockedGold,        title: "Kitchen Personality Quiz",    detail: "A short setup quiz so Stocked learns your dietary style, skill level, budget, and household size from day one."),
            ]
        ),
    ]

    /// The version string shown in Settings (always the newest entry)
    static var currentVersion: String {
        versions.first?.version ?? "0.1.5.7"
    }

    /// Build date of the newest release
    static var currentBuildDate: String {
        versions.first?.buildDate ?? ""
    }

    /// Build number shown in Settings — update with each new build
    static let currentBuildNumber: Int = 72
}

// MARK: - Changelog Sheet View

struct AppVersionView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @State private var expandedVersion: String? = nil

    var body: some View {
        StockedSheet(title: "What's New") {
            VStack(spacing: 0) {
                Text("Stocked. v\(StockedChangelog.currentVersion) · \(StockedChangelog.currentBuildDate)")
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 10)
                Divider().padding(.horizontal, 24)

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {   // perf: versions list grows every release
                        ForEach(StockedChangelog.versions) { ver in
                            versionSection(ver)
                        }
                        Color.clear.frame(height: 40)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Version section (collapsible)
    private func versionSection(_ ver: ChangelogVersion) -> some View {
        let isExpanded = expandedVersion == ver.version

        return VStack(alignment: .leading, spacing: 0) {
            // Version header row — tappable to expand/collapse
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    expandedVersion = isExpanded ? nil : ver.version
                }
            } label: {
                HStack(spacing: 12) {
                    // Version badge
                    Text("v\(ver.version)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(session.themeTextColor)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.stockedGold)
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(ver.headline)
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text(ver.buildDate)
                            .font(.system(size: 11))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            // Expanded entries
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ver.entries) { entry in
                        entryRow(entry)
                        if entry.id != ver.entries.last?.id {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                .background(Color.stockedWhite.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().padding(.horizontal, 16)
        }
    }

    // MARK: - Feature entry row
    private func entryRow(_ entry: ChangelogEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                    .fill(entry.color)
                    .frame(width: 38, height: 38)
                Image(systemName: entry.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 14, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text(entry.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    AppVersionView().environment(AppSession())
}
