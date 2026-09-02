// RegionalFoodData.swift — Feature 12: recipes don't travel, vocabulary does.
//
// A UK recipe says "aubergine, 200°C, 300 ml double cream". A US kitchen needs "eggplant, 400°F,
// 1 1/4 cups heavy cream". Getting this wrong ruins dinners, and it's the single biggest reason
// international recipes fail for people.
//
// Pure lookup + conversion, no network. Also powers the app's measurement-system preference.

import SwiftUI

// MARK: - Regions

nonisolated enum FoodRegion: String, CaseIterable, Codable, Sendable {
    case us = "US", uk = "UK", au = "Australia", metric = "Metric (EU)"

    var usesMetric: Bool { self != .us }
    var temperatureUnit: String { self == .us ? "°F" : "°C" }

    /// Best guess from the device locale, so the default is right without asking.
    static var deviceDefault: FoodRegion {
        switch Locale.current.region?.identifier {
        case "US", "LR", "MM": return .us
        case "GB", "IE":       return .uk
        case "AU", "NZ":       return .au
        default:               return .metric
        }
    }
}

// MARK: - Vocabulary

nonisolated struct IngredientAlias: Identifiable, Hashable, Sendable {
    var id: String { us }
    let us: String
    let uk: String
    let note: String

    func name(in region: FoodRegion) -> String { region == .us ? us : uk }
}

nonisolated enum RegionalFood {

    static let aliases: [IngredientAlias] = [
        .init(us: "Cilantro",           uk: "Coriander (fresh)",     note: "UK 'coriander' alone usually means the seed — check whether the recipe wants leaves or ground."),
        .init(us: "Eggplant",           uk: "Aubergine",             note: ""),
        .init(us: "Zucchini",           uk: "Courgette",             note: ""),
        .init(us: "Arugula",            uk: "Rocket",                note: ""),
        .init(us: "All-purpose flour",  uk: "Plain flour",           note: "UK plain flour is slightly lower in protein; for bread use strong/bread flour."),
        .init(us: "Heavy cream",        uk: "Double cream",          note: "Double cream is richer (~48% vs 36%). Whips faster — don't over-beat."),
        .init(us: "Half and half",      uk: "Single cream",          note: "Not identical; single cream is a bit richer."),
        .init(us: "Powdered sugar",     uk: "Icing sugar",           note: ""),
        .init(us: "Superfine sugar",    uk: "Caster sugar",          note: ""),
        .init(us: "Molasses",           uk: "Black treacle",         note: "Treacle is slightly more bitter."),
        .init(us: "Corn starch",        uk: "Cornflour",             note: "UK 'cornflour' is starch, NOT the US cornmeal-style flour."),
        .init(us: "Scallion",           uk: "Spring onion",          note: ""),
        .init(us: "Bell pepper",        uk: "Capsicum / pepper",     note: "Australia uses capsicum."),
        .init(us: "Ground beef",        uk: "Beef mince",            note: ""),
        .init(us: "Shrimp",             uk: "Prawns",                note: "Technically different animals; cook the same."),
        .init(us: "Beet",               uk: "Beetroot",              note: ""),
        .init(us: "Snow pea",           uk: "Mangetout",             note: ""),
        .init(us: "Baking soda",        uk: "Bicarbonate of soda",   note: ""),
        .init(us: "Broil",              uk: "Grill",                 note: "UK 'grill' = US broiler. UK 'barbecue' = US grill. This one causes real accidents."),
        .init(us: "Skillet",            uk: "Frying pan",            note: ""),
        .init(us: "Cookie",             uk: "Biscuit",               note: "And a US biscuit is closest to a UK scone."),
        .init(us: "Oatmeal",            uk: "Porridge oats",         note: ""),
        .init(us: "Canned",             uk: "Tinned",                note: ""),
        .init(us: "Confectioners glaze",uk: "Water icing",           note: ""),
        .init(us: "Graham cracker",     uk: "Digestive biscuit",     note: "The standard swap for cheesecake bases."),
        .init(us: "Jelly",              uk: "Jam",                   note: "UK 'jelly' is US 'Jell-O'."),
        .init(us: "Rutabaga",           uk: "Swede",                 note: ""),
        .init(us: "Chickpea",           uk: "Chickpea / garbanzo",   note: ""),
        .init(us: "Cotton candy",       uk: "Candy floss",           note: ""),
        .init(us: "Baking sheet",       uk: "Baking tray",           note: ""),
    ]

    /// Translate a whole ingredient line into the reader's region.
    static func translate(_ line: String, to region: FoodRegion) -> String {
        var out = line
        for alias in aliases {
            let from = region == .us ? alias.uk : alias.us
            let to = alias.name(in: region)
            guard !from.isEmpty else { continue }
            out = out.replacingOccurrences(of: from, with: to, options: [.caseInsensitive])
        }
        return out
    }

    static func search(_ query: String) -> [IngredientAlias] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return aliases }
        return aliases.filter {
            $0.us.lowercased().contains(q) || $0.uk.lowercased().contains(q)
        }
    }
}

// MARK: - Oven temperatures

nonisolated struct OvenTemp: Identifiable, Hashable, Sendable {
    var id: Int { fahrenheit }
    let fahrenheit: Int
    let celsius: Int
    let fanCelsius: Int
    let gasMark: String
    let description: String
}

nonisolated enum OvenScale {
    /// Standard conversions — the fan figure is 20°C below conventional, which is the rule most
    /// UK/AU recipes assume and US recipes never mention.
    static let all: [OvenTemp] = [
        .init(fahrenheit: 275, celsius: 140, fanCelsius: 120, gasMark: "1", description: "Very slow"),
        .init(fahrenheit: 300, celsius: 150, fanCelsius: 130, gasMark: "2", description: "Slow"),
        .init(fahrenheit: 325, celsius: 165, fanCelsius: 145, gasMark: "3", description: "Moderately slow"),
        .init(fahrenheit: 350, celsius: 180, fanCelsius: 160, gasMark: "4", description: "Moderate — most baking"),
        .init(fahrenheit: 375, celsius: 190, fanCelsius: 170, gasMark: "5", description: "Moderately hot"),
        .init(fahrenheit: 400, celsius: 200, fanCelsius: 180, gasMark: "6", description: "Hot — roasting"),
        .init(fahrenheit: 425, celsius: 220, fanCelsius: 200, gasMark: "7", description: "Hot"),
        .init(fahrenheit: 450, celsius: 230, fanCelsius: 210, gasMark: "8", description: "Very hot"),
        .init(fahrenheit: 475, celsius: 245, fanCelsius: 225, gasMark: "9", description: "Very hot — pizza"),
    ]

    static func fToC(_ f: Double) -> Double { (f - 32) * 5 / 9 }
    static func cToF(_ c: Double) -> Double { c * 9 / 5 + 32 }

    /// Nearest standard step, so we suggest "180°C" rather than "176.7°C".
    static func nearest(fahrenheit f: Int) -> OvenTemp? {
        all.min { abs($0.fahrenheit - f) < abs($1.fahrenheit - f) }
    }
}

// MARK: - Preference

@MainActor
@Observable
final class RegionPreference {
    static let shared = RegionPreference()
    private let key = "foodRegion_v1"

    var region: FoodRegion {
        didSet { UserDefaults.standard.set(region.rawValue, forKey: key) }
    }
    private init() {
        let saved = UserDefaults.standard.string(forKey: key) ?? ""
        region = FoodRegion(rawValue: saved) ?? FoodRegion.deviceDefault
    }
}

// MARK: - UI

struct RegionalFoodView: View {
    @Environment(AppSession.self) private var session
    private let pref = RegionPreference.shared
    @State private var search = ""
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Names").tag(0); Text("Oven").tag(1); Text("Translate").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 18).padding(.vertical, 10)

            switch tab {
            case 1: ovenList
            case 2: translatePane
            default: namesList
            }
        }
        .stockedScreen()
        .navigationTitle("Regional")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var namesList: some View {
        List {
            Section {
                Picker("My region", selection: Binding(get: { pref.region },
                                                       set: { pref.region = $0 })) {
                    ForEach(FoodRegion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } footer: {
                Text("Sets which name Stocked shows first, and which temperature scale it uses.")
            }
            Section {
                ForEach(RegionalFood.search(search)) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(a.us).scaledFont(14, weight: .semibold)
                            Image(systemName: "arrow.left.arrow.right")
                                .scaledFont(9).foregroundStyle(.secondary)
                            Text(a.uk).scaledFont(14, weight: .semibold)
                                .foregroundStyle(session.accentColor)
                        }
                        if !a.note.isEmpty {
                            Text(a.note).scaledFont(11).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: { Text("US ↔ UK / Australia") }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: "Find an ingredient")
    }

    private var ovenList: some View {
        List {
            Section {
                ForEach(OvenScale.all) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(t.fahrenheit)°F").frame(width: 62, alignment: .leading)
                            Text("\(t.celsius)°C").frame(width: 58, alignment: .leading)
                            Text("fan \(t.fanCelsius)°").frame(width: 66, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text("gas \(t.gasMark)").foregroundStyle(.secondary)
                        }
                        .scaledFont(13, weight: .medium, design: .monospaced)
                        Text(t.description).scaledFont(11).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("Fan (convection) ovens run hotter — drop 20°C / about 25°F from the conventional figure, or your bake browns before it cooks through.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @State private var toTranslate = ""
    private var translatePane: some View {
        List {
            Section {
                TextField("Paste an ingredient list", text: $toTranslate, axis: .vertical)
                    .lineLimit(4...)
            } header: { Text("Original") }
            if !toTranslate.isEmpty {
                Section {
                    Text(RegionalFood.translate(toTranslate, to: pref.region))
                        .scaledFont(14).foregroundStyle(session.themeTextColor)
                } header: { Text("In \(pref.region.rawValue) terms") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}
