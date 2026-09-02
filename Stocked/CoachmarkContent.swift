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
        .spotlight("inv.assistant",
                   title: "Inventory Assistant",
                   body: "Change your inventory just by asking. Say what you used, set a level, add something you bought, or clear everything, and confirm the changes before they apply."),
        .spotlight("inv.expiring",
                   title: "Expiring soon",
                   body: "Food that's close to its date shows up here so you can use it before it's wasted. When there's a list, tap View All to see all of it."),
        .card(title: "Swipe, search, and sort",
              body: "Swipe left on any item to delete it, with a quick undo if you change your mind. Use Search and Sort at the top right to find an item fast or reorder the list."),
        .card(title: "Pull down to refresh",
              body: "Pull down on this screen, or almost any screen, to refresh. If you share a household, it also pulls everyone's latest changes right away."),
        .card(title: "Reservations stay visible",
              body: "Meals you plan can reserve pantry ingredients. Inventory shows what is available versus reserved and warns when future meals compete for the same food."),
        .card(title: "More ways to update",
              body: "Add items by hand, scan a barcode or receipt, use the Inventory Assistant, or review an AI inventory scan before any proposed changes are applied."),
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
        .spotlight("recipes.createAI",
                   title: "Create with AI",
                   body: "Describe what you want to cook and Stocked builds a full recipe you can save. List ingredients you have and pick a dietary preference or time limit to tailor it."),
        .spotlight("recipes.sources",
                   title: "Browse by source",
                   body: "See every place recipes come from, live feeds and dozens of recipe websites including any you add yourself, then dive into recipes from any single source."),
        .spotlight("recipes.drinks",
                   title: "The Drinks section",
                   body: "Cocktails, mocktails, coffees, shakes, and party drinks now have a home of their own, grouped by type and refreshed with a pull."),
        .card(title: "Find a recipe fast",
              body: "Tap the search icon at the top right to search recipes directly. Scroll down to Discover for ideas based on what is in your kitchen right now."),
        .card(title: "Fresh ideas on each visit",
              body: "Recipe rails refresh once when you visit Recipes and whenever you manually refresh. Cards use verified recipe images and adapt to your chosen text and interface size."),
        .card(title: "Save, import, and organize",
              body: "Create a recipe manually or with AI, import from supported websites and shared links, mark favorites, track what you cooked, and organize recipes into collections."),
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
        .card(title: "Swipe to remove",
              body: "Swipe left on any list item to delete it, with undo. Swiping a low-stock suggestion removes that item from your kitchen, so it asks first."),
        .card(title: "Store, share, and scan",
              body: "Tap the menu at the top right to set your store, share the list with someone, scan a paper list, or move checked items into your pantry."),
        .card(title: "Plan-aware shopping",
              body: "Meal plans can add combined missing ingredients automatically. Stocked keeps bought items separate and can move them into Inventory when the trip is done."),
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
                   body: "Use Plan, Shop, and Prep in one workspace. Add meals to the week, open ingredient checks, catch over-allocation, review combined shopping needs, and complete prep before cooking."),
        .card(title: "Three ways to find a meal",
              body: "Inside Cook Now you can Build Around Food you choose, Match My Mood with a few quick questions, or hit Surprise Me to let the app pick for you. Match My Mood always lands on a recipe, checking the web, your database, and AI in turn."),
        .card(title: "Cook with confidence",
              body: "Check substitutions and missing ingredients, compare cooking methods and equipment, prepare components, follow the live cooking workspace, then record what was eaten or saved."),
        .card(title: "Plan, shop, prep, cook",
              body: "Cook Later carries a meal through the whole week: reserve pantry food, combine shopping needs, finish prep tasks, start cooking, and review the completed session."),
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
        // (The "Daily Brief" widget spotlight was removed: the Daily Brief card isn't in the
        // default Home layout — default widgets are Stock Level, Action Center, Use It Soon and
        // Tip of the Day — so it spotlighted nothing and floated as a stray card. The Brief is
        // fully covered by the next step, which opens it from the title.)
        .spotlight("shell.title",
                   title: "Open your Daily Brief",
                   body: "Tap the Stocked title at the top of the screen any time to open your full Daily Brief: a quick rundown of what's expiring, what's low, and what's worth cooking today."),
        .card(title: "Make it yours",
              body: "Touch and hold with one finger on Home to enter widget editing. Drag any widget to reorder it, drop it on the X to remove it, or tap the page background to finish."),
        .card(title: "Find everything in the menu",
              body: "Swipe from the left edge, or tap the menu icon, to open the side menu. Your profile, settings, tools, and help all live there — plus the Kitchen Toolbox, dozens of extra tools in one place."),
        .card(title: "Make the menu yours",
              body: "In the side menu, press and hold any row under Kitchen Tools or Insights and drag to reorder. Pull down on any screen to refresh it."),
        .card(title: "Size the whole app for you",
              body: "Settings lets you choose the app font, seven app-wide text sizes, and a separate recipe reading size. Pages, sheets, cards, buttons, and text grow or wrap without cutting labels off."),
        .card(title: "Report an issue in QA mode",
              body: "When QA mode is enabled, short-press with two fingers anywhere—or shake the device—to capture the current screen and open a QA ticket with diagnostics attached."),
    ]
}
