// CoachmarkContent.swift — per-page coachmark step definitions (Build 298).
//
// Each page exposes an ordered list of steps consumed by .coachmarks(page:steps:). Spotlight
// steps reference a .coachmarkAnchor(id) placed on the matching element in that page's view.
// Card steps are centered and used for lower-tier or easily-missed things (per the design).
//
// Home is defined here first; the other four pages are added in following builds as their
// anchors are placed.

import SwiftUI

enum InventoryCoachmarks {
    static let steps: [CoachmarkStep] = [
        .spotlight("inv.status",
                   title: "Your kitchen at a glance",
                   body: "This card shows how well stocked you are overall, with a percentage and a quick read on which zones are running low."),
        .spotlight("inv.categories",
                   title: "Browse by category",
                   body: "Tap any category to jump straight to those items. It is the fastest way to find what you are looking for."),
        .spotlight("inv.expiring",
                   title: "Expiring soon",
                   body: "A preview of items that need using up soon. Tap View All to see the full list and cook them before they go to waste."),
        .card(title: "Search and sort",
              body: "Use the Search and Sort buttons at the top right to find a specific item fast or reorder the whole list by name, quantity, or what to use first."),
    ]
}

enum RecipeCoachmarks {
    static let steps: [CoachmarkStep] = [
        .spotlight("recipes.hub",
                   title: "Your recipe collection",
                   body: "Your saved recipes live here: favorites, ones you have cooked, everything you have saved, and your collections by cuisine."),
        .spotlight("recipes.categories",
                   title: "Browse by cuisine",
                   body: "Explore new recipes online, organized by cuisine, to find something fresh to add to your collection."),
        .card(title: "Find a recipe fast",
              body: "Tap the search icon at the top right to search recipes directly. Scroll down to Discover for ideas based on what is in your kitchen right now."),
    ]
}

enum GroceryCoachmarks {
    static let steps: [CoachmarkStep] = [
        .spotlight("grocery.segments",
                   title: "To Buy and Bought",
                   body: "Switch between what you still need to buy and what you have already picked up. Items move to Bought as you check them off."),
        .spotlight("grocery.add",
                   title: "Add to your list",
                   body: "Tap Add Item to put anything on your list by hand. Ingredients from meals you plan also show up here automatically."),
        .card(title: "Store, share, and scan",
              body: "Tap the menu at the top right to set your store, share the list with someone, scan a paper list, or move checked items into your pantry."),
    ]
}

enum CookCoachmarks {
    static let steps: [CoachmarkStep] = [
        .spotlight("cook.header",
                   title: "Decide what to cook",
                   body: "This is the Cook tab. It helps you answer one question: what should I make? Two ways in, depending on whether you are cooking now or planning ahead."),
        .spotlight("cook.now",
                   title: "Cook Now",
                   body: "Solve dinner tonight. The app builds suggestions around what you already have, so you can cook without a grocery run."),
        .spotlight("cook.later",
                   title: "Cook Later",
                   body: "Plan meals for the week ahead, build a prep list, and turn your plan into a grocery list in a couple of taps."),
        .card(title: "Three ways to find a meal",
              body: "Inside Cook Now you can Build Around Food you choose, Match My Mood with a few quick questions, or hit Surprise Me to let the app pick for you."),
    ]
}

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
                   body: "This card is a quick preview of your kitchen today: what is expiring, what is low, and what is worth cooking."),
        .spotlight("shell.title",
                   title: "Open your Daily Brief",
                   body: "Tap the Stocked title at the top of the screen any time to open your full Daily Brief, with the complete rundown for the day."),
        .card(title: "Make it yours",
              body: "Press and hold anywhere on Home to customize. You can drag widgets to reorder them, remove ones you do not use, and add new ones from the gallery."),
        .card(title: "Find everything in the menu",
              body: "Swipe from the left edge, or tap the menu icon, to open the side menu. Your profile, settings, tools, and help all live there."),
    ]
}
