import AnalyticoKit
import SwiftUI

/// The workspace's palette and display face, so the apps read as Analytico.
enum Theme {
    static let brand = Color(red: 0.839, green: 0.286, blue: 0.216)
    static let good = Color(red: 0.133, green: 0.439, blue: 0.290)
    static let bad = Color(red: 0.624, green: 0.114, blue: 0.125)
    static let warning = Color(red: 0.604, green: 0.357, blue: 0.031)
    static let brandWash = Color(red: 0.984, green: 0.929, blue: 0.918)

    /// Quando, the workspace's display face, for titles only.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom("Quando-Regular", size: size, relativeTo: style)
    }
}

/// The Analytico mark: three rising bars on the brand tile.
struct Mark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: size * 0.25).fill(Theme.brand)
            HStack(alignment: .bottom, spacing: size * 0.07) {
                bar(height: 0.25)
                bar(height: 0.42)
                bar(height: 0.54)
            }
            .padding(.leading, size * 0.25)
            .padding(.bottom, size * 0.25)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.04).fill(.white).frame(width: size * 0.125, height: size * height)
    }
}

/// "+12.4%" in green, "−2.1%" in red, with the comparison after it.
struct ChangeLabel: View {
    let change: AnalyticoKit.Format.Change
    var suffix: String = ""

    var body: some View {
        HStack(spacing: 4) {
            Text(change.text)
                .foregroundStyle(change.direction == .up ? Theme.good : change.direction == .down ? Theme.bad : .secondary)
                .fontWeight(.semibold)
            if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
        }
        .font(.caption)
        .monospacedDigit()
    }
}
