import Foundation

/// Prepper-oriented subject taxonomy used to organise hoards ("what's where") and to filter search.
public enum Subject: String, CaseIterable, Codable, Sendable, Identifiable {
    case medical, water, food, shelter, power, communications, navigation, repair, security, gardening, sanitation, weather, skills, reference, entertainment, general
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .medical: return "Medical & first aid"
        case .water: return "Water"
        case .food: return "Food & preservation"
        case .shelter: return "Shelter & heat"
        case .power: return "Power & solar"
        case .communications: return "Radio & comms"
        case .navigation: return "Maps & navigation"
        case .repair: return "Repair & tools"
        case .security: return "Security & defence"
        case .gardening: return "Gardening & livestock"
        case .sanitation: return "Hygiene & sanitation"
        case .weather: return "Weather & hazards"
        case .skills: return "Field skills"
        case .reference: return "Reference"
        case .entertainment: return "Entertainment & morale"
        case .general: return "General"
        }
    }
    public var systemImage: String {
        switch self {
        case .medical: return "cross.case"; case .water: return "drop"; case .food: return "fork.knife"; case .shelter: return "house"
        case .power: return "bolt"; case .communications: return "antenna.radiowaves.left.and.right"; case .navigation: return "map"; case .repair: return "wrench.and.screwdriver"
        case .security: return "shield"; case .gardening: return "leaf"; case .sanitation: return "hands.sparkles"; case .weather: return "cloud.bolt.rain"
        case .skills: return "figure.hiking"; case .reference: return "books.vertical"; case .entertainment: return "music.note"; case .general: return "doc"
        }
    }
}

/// Keyword-weighted classifier over title + leading text. Deliberately simple, transparent and offline.
public enum SubjectClassifier {
    static let keywords: [Subject: [String]] = [
        .medical: ["first aid", "medic", "wound", "bleeding", "fracture", "cpr", "trauma", "triage", "antibiotic", "dosage", "symptom", "diagnos", "nursing", "dental", "pharmac", "injur", "burn", "shock", "airway", "splint", "tourniquet", "infection", "disease", "hospital", "doctor", "midwi", "obstetric", "pediatric"],
        .water: ["water purif", "water treatment", "potable", "disinfect", "chlorin", "bleach", "filtration", "rainwater", "well water", "boil water", "drinking water", "cistern", "water storage"],
        .food: ["canning", "preserv", "pressure canner", "dehydrat", "food storage", "recipe", "cookbook", "butcher", "smoking meat", "fermentation", "pantry", "ration", "nutrition", "forag", "edible plant", "mushroom", "cooking"],
        .shelter: ["shelter", "insulation", "wood stove", "heating", "tarp", "tent", "cabin", "roofing", "chimney", "hypothermia", "firewood", "bivouac"],
        .power: ["solar", "photovoltaic", "inverter", "battery", "generator", "charge controller", "off-grid power", "wiring", "voltage", "lifepo4", "wind turbine", "electrical"],
        .communications: ["ham radio", "amateur radio", "radio", "repeater", "frequenc", "antenna", "meshtastic", "lora", "shortwave", "gmrs", "frs ", "sdr", "morse", "fcc", "transceiver", "mhz", "baofeng", "walkie"],
        .navigation: ["map", "compass", "navigation", "topograph", "gps", "orienteering", "bearing", "latitude", "trail", "route"],
        .repair: ["repair", "manual", "service manual", "troubleshoot", "maintenance", "engine", "carburet", "chainsaw", "welding", "plumbing", "ifixit", "schematic", "parts list", "tractor", "small engine"],
        .security: ["self-defense", "self defence", "firearm", "rifle", "ammunition", "perimeter", "opsec", "security", "patrol", "marksman", "ballistic"],
        .gardening: ["garden", "seed", "compost", "soil", "permaculture", "livestock", "chicken", "goat", "beekeep", "orchard", "crop", "harvest", "irrigation", "greenhouse", "poultry"],
        .sanitation: ["sanitation", "latrine", "hygiene", "sewage", "composting toilet", "waste disposal", "handwashing", "field hygiene", "vector control", "pest"],
        .weather: ["weather", "hurricane", "tornado", "flood", "wildfire", "earthquake", "storm", "lightning", "blizzard", "heat wave", "tsunami", "volcan", "nuclear", "fallout", "radiation", "emergency preparedness", "disaster", "evacuat"],
        .skills: ["survival", "bushcraft", "knot", "fire starting", "tracking", "fishing", "hunting", "trapping", "snare", "signal", "evasion", "field craft", "camp"],
        .reference: ["encyclopedia", "encyclopaedia", "dictionary", "handbook", "almanac", "formulas", "tables", "chemistry", "physics", "mathematics", "engineering"],
        .entertainment: ["novel", "fiction", "poetry", "music", "songbook", "games", "puzzle", "stories", "children", "comic"],
    ]

    public static func classify(_ text: String) -> Subject {
        let lower = text.lowercased()
        let titleLine = lower.split(separator: "\n").first.map(String.init) ?? ""
        var scores: [Subject: Int] = [:]
        for (subject, words) in keywords {
            var s = 0
            for w in words {
                let n = lower.components(separatedBy: w).count - 1
                if n > 0 { s += min(n, 6) + (titleLine.contains(w) ? 8 : 0) }
            }
            if s > 0 { scores[subject] = s }
        }
        guard let best = scores.max(by: { $0.value < $1.value }), best.value >= 3 else { return .general }
        return best.key
    }
}
