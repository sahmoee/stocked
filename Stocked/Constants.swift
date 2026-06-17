// Constants.swift — All magic strings, URLs, keys (Code Professional #7)
import Foundation
import SwiftUI

enum StockedKeys {
    static let inventory        = "inv"
    static let grocery          = "groc"
    static let pastMeals        = "meals"
    static let generated        = "genr"
    static let userRecipes      = "userRecipes_v1"
    static let cookingProfile   = "cookingProfile_v1"
    static let ocrDict          = "ocrDict_v1"
    static let guestName        = "guestName"
    static let groceryDay       = "groceryDay"
    static let wasGuest         = "wasGuest"
    static let darkMode         = "darkMode"
    static let appTheme         = "appTheme"
    static let appFont          = "appFont"
    static let boltPosition     = "boltPosition"
    static let boltSize         = "boltSize"
    static let boltOffX         = "boltOffX"
    static let boltOffY         = "boltOffY"
    static let homeLayout       = "homeLayout"
    static let accentR          = "accentR"
    static let accentG          = "accentG"
    static let accentB          = "accentB"
    static let bgR              = "bgR"
    static let bgG              = "bgG"
    static let bgB              = "bgB"
    static let notificationsEnabled = "notificationsEnabled"
    static let offlineRecipeCache   = "offlineRecipeCache_v1"
    static let usageTracking        = "ingredientUsage_v1"
    static let firstLaunchFlags     = "firstLaunchFlags_v1"
    static let cookingProgress      = "cookingProgress_v1"
    static let ratingWeights        = "ratingWeights_v1"
}

// Shared URLSession with sane timeouts — use instead of URLSession.shared
extension URLSession {
    static let stocked: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 12
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity       = true
        return URLSession(configuration: config)
    }()
}

enum StockedAPI {
    static let mealDBBase   = "https://www.themealdb.com/api/json/v1/1"
    static let mealSearch   = "\(mealDBBase)/search.php?s="
    static let mealRandom   = "\(mealDBBase)/random.php"
    static let mealByID     = "\(mealDBBase)/lookup.php?i="
    static let openFoodFacts = "https://world.openfoodfacts.org/api/v0/product"
    static let anthropicMessages = "https://api.anthropic.com/v1/messages"
    static let anthropicModel    = "claude-sonnet-4-20250514"
}

enum StockedUI {
    static let cornerRadiusSm: CGFloat = 8    // badges, chips, thumbnails
    static let cornerRadiusMd: CGFloat = 12   // cards, input fields, list rows
    static let cornerRadiusLg: CGFloat = 20   // sheets, modals, large overlays
    static let cornerRadiusXL: CGFloat = 30   // pills, primary buttons, capsules
    static let animationFast            = 0.18
    static let animationMd              = 0.28
    static let animationSlow            = 0.45
    static let offlineCacheLimit        = 100
    static let undoToastDuration        = 4.0
    static let skeletonRows             = 4
    static let scrollBottomPad: CGFloat  = 120  // safe clearance below scroll content
    static let navHeight:        CGFloat  = 68   // global bottom navigation height
}

// Accessibility IDs (Code Professional #13)
enum A11y {
    static let tabHome = "tab_home"; static let tabPantry = "tab_pantry"
    static let tabRecipes = "tab_recipes"; static let tabGrocery = "tab_grocery"
    static let btnCookNow = "btn_cook_now"; static let btnCookLater = "btn_cook_later"
    static let eyeToggle = "btn_eye_toggle"; static let addItem = "btn_add_item"
    static let scanBarcode = "btn_scan_barcode"; static let scanReceipt = "btn_scan_receipt"
    static let boltButton = "btn_bolt"; static let globalSearch = "btn_global_search"
    static let startCooking = "btn_start_cooking"; static let finishCooking = "btn_finish_cooking"
}
