import Foundation

/// Numbers the way the workspace shows them, in the reader's locale.
public enum Format {
    /// "18,420" (or "18.420" in German).
    public static func count(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }

    /// Change against the previous period: "+12.4%", "−2.1%", "0.0%",
    /// "new" from nothing, and from three times the previous value up a
    /// multiple: "6.4×", "22×".
    public static func change(_ current: Double, _ previous: Double, locale: Locale = .current) -> Change {
        if previous == 0 { return Change(text: current == 0 ? "0.0%".replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".") : "new", direction: current == 0 ? .flat : .up) }
        let percent = (current - previous) / previous * 100
        let times = current / previous
        if times >= 10 { return Change(text: "\(Int(times.rounded()))×", direction: .up) }
        if times >= 3 { return Change(text: times.formatted(.number.precision(.fractionLength(1)).locale(locale)) + "×", direction: .up) }
        let rounded = (percent * 10).rounded() / 10
        let magnitude = abs(rounded).formatted(.number.precision(.fractionLength(1)).locale(locale))
        if rounded > 0 { return Change(text: "+\(magnitude)%", direction: .up) }
        if rounded < 0 { return Change(text: "−\(magnitude)%", direction: .down) }
        return Change(text: "0.0%".replacingOccurrences(of: ".", with: locale.decimalSeparator ?? "."), direction: .flat)
    }

    public struct Change: Equatable, Sendable {
        public enum Direction: Sendable { case up, down, flat }
        public var text: String
        public var direction: Direction

        public init(text: String, direction: Direction) {
            self.text = text
            self.direction = direction
        }
    }

    /// Active time: "38s", "2m 41s", "1h 05m".
    public static func duration(milliseconds: Double) -> String {
        let seconds = Int((milliseconds / 1000).rounded())
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(String(format: "%02d", seconds % 60))s" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    /// Web Vitals: "340 ms", "1.8 s"; layout shift "0.12".
    public static func vital(_ value: Double, layoutShift: Bool = false, locale: Locale = .current) -> String {
        if layoutShift { return (value / 1000).formatted(.number.precision(.fractionLength(2)).locale(locale)) }
        if value < 1000 { return "\(Int(value)) ms" }
        return (value / 1000).formatted(.number.precision(.fractionLength(1)).locale(locale)) + " s"
    }

    /// Money from minor units: "€1,234.50".
    public static func money(minor: Int, currency: String, locale: Locale = .current) -> String {
        (Double(minor) / 100).formatted(.currency(code: currency).locale(locale))
    }

    /// Share as a percentage: "42%".
    public static func share(_ part: Double, of whole: Double, locale: Locale = .current) -> String {
        whole == 0 ? "0%" : (part / whole).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}
