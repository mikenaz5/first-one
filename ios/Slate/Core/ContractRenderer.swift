import Foundation

/// Locale-independent formatting for contract text. A contract must read identically on every
/// device and on the server, so nothing here uses `DateFormatter` or the user's region settings.
/// The SQL functions `contract_money`, `contract_long_date`, `contract_time` and friends mirror this.
enum ContractFormat {
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let months = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// "$2,400", "$2,400.50", "EUR 2,400".
    static func money(cents: Int, code: String) -> String {
        let whole = abs(cents) / 100
        let fraction = abs(cents) % 100
        let sign = cents < 0 ? "-" : ""
        let prefix = code == "USD" ? "$" : "\(code) "
        let digits = fraction == 0 ? grouped(whole) : "\(grouped(whole)).\(fraction < 10 ? "0" : "")\(fraction)"
        return "\(sign)\(prefix)\(digits)"
    }

    private static func grouped(_ value: Int) -> String {
        let digits = Array(String(value))
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return result
    }

    /// "Thursday, December 4, 2026"
    static func longDate(_ day: CalendarDay, calendar: Calendar) -> String {
        let weekday = weekdays[day.weekday(in: calendar) - 1]
        return "\(weekday), \(months[day.month - 1]) \(day.day), \(day.year)"
    }

    static func longDate(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return longDate(CalendarDay(date, calendar: calendar), calendar: calendar)
    }

    /// "9:05 AM", "12:00 PM"
    static func time(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour24 = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return "\(hour12):\(minute < 10 ? "0" : "")\(minute) \(hour24 < 12 ? "AM" : "PM")"
    }

    /// "10:00 AM – 12:00 PM" (with an en dash).
    static func timeRange(start: Date, end: Date, in timeZone: TimeZone) -> String {
        "\(time(start, in: timeZone)) – \(time(end, in: timeZone))"
    }

    /// "2 hours", "1 hour 30 minutes", "45 minutes".
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if rest > 0 || parts.isEmpty { parts.append("\(rest) minute\(rest == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }

    /// "2026-10-21 23:31:46 UTC": an unambiguous timestamp for signature records.
    static func timestampUTC(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "\(parts.year ?? 1970)-\(two(parts.month))-\(two(parts.day)) \(two(parts.hour)):\(two(parts.minute)):\(two(parts.second)) UTC"
    }

    /// "1 day", "14 days".
    static func days(_ count: Int) -> String {
        "\(count) day\(count == 1 ? "" : "s")"
    }

    private static let asciiWhitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"]

    /// Makes a person-supplied string safe to place in a contract, so a client named "{{price}}"
    /// can't rewrite it. Mirrors `contract_sanitize` in SQL exactly:
    /// - no two braces in a row survive ("{{{" becomes "{ { {");
    /// - whitespace means ASCII whitespace only (never the locale's idea of it). It collapses to single
    ///   spaces, unless line breaks are kept, in which case CRLF and CR become LF.
    static func sanitize(_ value: String, keepLineBreaks: Bool = false) -> String {
        let input = Array(value.unicodeScalars)
        var output: [Unicode.Scalar] = []
        var index = 0
        var inSpace = false

        while index < input.count {
            let scalar = input[index]
            let next = index + 1 < input.count ? input[index + 1] : nil
            index += 1

            if keepLineBreaks {
                if scalar == "\r" {
                    if next == "\n" { continue } // The LF that follows is kept instead.
                    output.append("\n")
                    continue
                }
            } else if asciiWhitespace.contains(scalar) {
                if !inSpace { output.append(" ") }
                inSpace = true
                continue
            }
            inSpace = false

            output.append(scalar)
            if (scalar == "{" || scalar == "}") && next == scalar { output.append(" ") }
        }

        while let first = output.first, asciiWhitespace.contains(first) { output.removeFirst() }
        while let last = output.last, asciiWhitespace.contains(last) { output.removeLast() }

        var result = String.UnicodeScalarView()
        result.append(contentsOf: output)
        return String(result)
    }
}

// MARK: - Context

enum ContractContextBuilder {
    /// Every value a template can use, for one booking. Pure: the same inputs always give the same text.
    static func make(
        package: ServicePackage,
        addOns: [AddOn],
        start: Date,
        timeZone: TimeZone,
        clientName: String,
        creatorName: String,
        notes: String
    ) -> [ContractField: String] {
        let duration = package.durationMinutes(with: addOns)
        let end = start.addingTimeInterval(Double(duration) * 60)
        let summary = PriceSummary.make(package: package, addOns: addOns)
        let turnaround = package.turnaroundDays(with: addOns)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let shootDay = CalendarDay(start, calendar: calendar)
        let deliveryDay = shootDay.adding(days: turnaround, in: calendar)

        let deliverables = package.deliverables.isEmpty
            ? "As described in the package"
            : package.deliverables.map { "• \(ContractFormat.sanitize($0))" }.joined(separator: "\n")
        let addOnLines = addOns.isEmpty
            ? "None"
            : addOns.map { "• \(ContractFormat.sanitize($0.name)) (+\(ContractFormat.money(cents: $0.priceCents, code: package.currencyCode)))" }.joined(separator: "\n")
        let trimmedNotes = ContractFormat.sanitize(notes, keepLineBreaks: true)

        let name = ContractFormat.sanitize(clientName)
        return [
            .clientName: name.isEmpty ? "the Client" : name,
            .creatorName: ContractFormat.sanitize(creatorName),
            .packageName: ContractFormat.sanitize(package.name),
            .bookingDate: ContractFormat.longDate(shootDay, calendar: calendar),
            .bookingTime: ContractFormat.timeRange(start: start, end: end, in: timeZone),
            .timeZone: timeZone.identifier,
            .duration: ContractFormat.duration(minutes: duration),
            .deliverables: deliverables,
            .addOns: addOnLines,
            .price: ContractFormat.money(cents: summary.totalCents, code: package.currencyCode),
            .deposit: ContractFormat.money(cents: summary.depositCents, code: package.currencyCode),
            .balance: ContractFormat.money(cents: summary.balanceCents, code: package.currencyCode),
            .turnaround: ContractFormat.days(turnaround),
            .deliveryDate: ContractFormat.longDate(deliveryDay, calendar: calendar),
            .cancellationPolicy: package.cancellationPolicy.contractText,
            .usageRights: package.usageRights.contractText,
            .clientNotes: trimmedNotes.isEmpty ? "None" : trimmedNotes,
        ]
    }

    /// Believable values for previewing a template while it is being edited.
    static var sample: [ContractField: String] {
        Dictionary(uniqueKeysWithValues: ContractField.allCases.map { ($0, $0.sample) })
    }
}

// MARK: - Renderer

enum ContractRenderer {
    /// Replaces each `{{token}}` once, in a single pass, so a value can never be re-interpreted as a placeholder.
    /// Tokens that aren't known fields are left as written (the editor refuses to save those).
    static func fill(_ text: String, with values: [ContractField: String]) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("{{"),
               let close = text.range(of: "}}", range: index..<text.endIndex) {
                let tokenStart = text.index(index, offsetBy: 2)
                let name = String(text[tokenStart..<close.lowerBound])
                if let field = ContractField(rawValue: name), let value = values[field] {
                    output += value
                } else {
                    output += String(text[index..<close.upperBound])
                }
                index = close.upperBound
            } else {
                output.append(text[index])
                index = text.index(after: index)
            }
        }
        return output
    }

    static func render(template: ContractTemplate, values: [ContractField: String]) -> RenderedContract {
        RenderedContract(
            title: fill(template.title, with: values),
            sections: template.clauses.map {
                ContractSection(title: fill($0.title, with: values), body: fill($0.body, with: values))
            },
            templateID: template.id,
            templateVersion: template.version
        )
    }

    /// The names inside `{{...}}` in a piece of text, in order of appearance.
    static func tokens(in text: String) -> [String] {
        var found: [String] = []
        var index = text.startIndex
        while let open = text.range(of: "{{", range: index..<text.endIndex) {
            guard let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) else { break }
            found.append(String(text[open.upperBound..<close.lowerBound]))
            index = close.upperBound
        }
        return found
    }

    static func tokens(in template: ContractTemplate) -> Set<String> {
        var all = Set(tokens(in: template.title))
        for clause in template.clauses {
            all.formUnion(tokens(in: clause.title))
            all.formUnion(tokens(in: clause.body))
        }
        return all
    }
}
