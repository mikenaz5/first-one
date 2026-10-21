import Foundation

// MARK: - Handles

/// Rules for the `slate.example/<handle>` booking link name.
/// Keep in sync with the CHECK constraint in supabase/migrations.
enum HandleRules {
    static let minLength = 3
    static let maxLength = 30

    static let reserved: Set<String> = [
        "admin", "api", "app", "about", "bookings", "contracts", "help", "login",
        "messages", "privacy", "profile", "services", "settings", "signup",
        "slate", "support", "terms", "www",
    ]

    enum Problem: Equatable {
        case tooShort
        case tooLong
        case invalidCharacters
        case badEdges
        case reserved

        var message: String {
            switch self {
            case .tooShort: "Use at least \(HandleRules.minLength) characters."
            case .tooLong: "Use at most \(HandleRules.maxLength) characters."
            case .invalidCharacters: "Use letters, numbers, hyphens and underscores."
            case .badEdges: "Start and end with a letter or number."
            case .reserved: "That name is reserved."
            }
        }
    }

    /// Lowercases, turns spaces and dots into hyphens, drops anything else not allowed,
    /// and collapses repeated separators. Safe to apply on every keystroke.
    static func normalize(_ raw: String) -> String {
        var output = ""
        for character in raw.lowercased() {
            let mapped: Character?
            if character.isASCII, character.isLetter || character.isNumber {
                mapped = character
            } else if character == "-" || character == "_" {
                mapped = character
            } else if character == " " || character == "." {
                mapped = "-"
            } else {
                mapped = nil
            }
            guard let mapped else { continue }
            if (mapped == "-" || mapped == "_"), let last = output.last, last == "-" || last == "_" {
                continue
            }
            output.append(mapped)
        }
        // A handle can't start with a separator, so don't let one in.
        while let first = output.first, first == "-" || first == "_" {
            output.removeFirst()
        }
        return String(output.prefix(maxLength))
    }

    static func validate(_ handle: String) -> Problem? {
        if handle.count < minLength { return .tooShort }
        if handle.count > maxLength { return .tooLong }
        let allowed = handle.allSatisfy { character in
            character.isASCII && (character.isLowercase || character.isNumber)
                || character == "-" || character == "_"
        }
        if !allowed { return .invalidCharacters }
        if let first = handle.first, let last = handle.last {
            let edgesOK = (first.isLetter || first.isNumber) && (last.isLetter || last.isNumber)
            if !edgesOK { return .badEdges }
        }
        if reserved.contains(handle) { return .reserved }
        return nil
    }

    /// "Maya Chen Studio" -> "maya-chen-studio"
    static func suggestion(from displayName: String) -> String {
        var suggestion = normalize(displayName)
        while let last = suggestion.last, last == "-" || last == "_" {
            suggestion.removeLast()
        }
        return suggestion
    }
}

// MARK: - Travel radius

/// Travel radius is stored in kilometers and shown in the person's own unit.
enum TravelRadius {
    static let defaultKm = 40

    static var usesMiles: Bool {
        let system = Locale.current.measurementSystem
        return system == .us || system == .uk
    }

    /// Presets in kilometers. In miles regions they land on 10, 25, 50, 100 and 250 miles.
    static func presets(usesMiles: Bool = TravelRadius.usesMiles) -> [Int] {
        usesMiles ? [16, 40, 80, 160, 400] : [10, 25, 50, 100, 250]
    }

    static func label(km: Int, usesMiles: Bool = TravelRadius.usesMiles) -> String {
        if usesMiles {
            let miles = Double(km) * 0.621371
            let rounded = max(5, Int((miles / 5).rounded()) * 5)
            return "\(rounded) mi"
        }
        return "\(km) km"
    }

    /// Nearest preset, so a value saved in another region still selects something.
    static func nearestPreset(to km: Int, usesMiles: Bool = TravelRadius.usesMiles) -> Int {
        presets(usesMiles: usesMiles).min { abs($0 - km) < abs($1 - km) } ?? defaultKm
    }
}
