// CoachmarkContent.swift — per-page coachmark step definitions (Build 298).
//
// Each page exposes an ordered list of steps consumed by .coachmarks(page:steps:). Spotlight
// steps reference a .coachmarkAnchor(id) placed on the matching element in that page's view.
// Card steps are centered and used for lower-tier or easily-missed things (per the design).
//
// Home is defined here first; the other four pages are added in following builds as their
// anchors are placed.

import SwiftUI

enum HomeCoachmarks {
    static let steps: [CoachmarkStep] = [
        .spotlight("home.greeting",
                   title: "Welcome to your kitchen",
                   body: "This is your Home dashboard. At a glance it shows what is happening across your pantry, meals, and shopping.",
                   pad: 18),
        .spotlight("home.widget.actionCenter",
                   title: "Action Center",
                   body: "Jump straight into the things you do most: scan a receipt, scan a barcode, add an item by hand, or tell the app what changed."),
        .spotlight("home.widget.useItSoon",
                   title: "Use It Soon",
                   body: "Items that are close to expiring show up here so you can cook them before they go to waste."),
        .spotlight("home.widget.dailyBrief",
                   title: "Daily Brief",
                   body: "A quick daily summary of your kitchen: what is expiring, what is low, and what is worth cooking today."),
        .card(title: "Make it yours",
              body: "Press and hold anywhere on Home to customize. You can drag widgets to reorder them, remove ones you do not use, and add new ones from the gallery."),
        .card(title: "Find everything in the menu",
              body: "Swipe from the left edge, or tap the menu icon, to open the side menu. Your profile, settings, tools, and help all live there."),
    ]
}
