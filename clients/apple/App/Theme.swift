import AnalyticoKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The workspace's tokens, light and dark, the same values as the web's
/// app.css: warm canvas, white cards, brand red only for what is selected or
/// primary, Quando for titles and numbers.
enum Theme {
    static let canvas = Color(light: 0xF7F5F4, dark: 0x171412)
    static let surface = Color(light: 0xFFFFFF, dark: 0x211D1B)
    static let subtle = Color(light: 0xF3EFED, dark: 0x2A2522)
    static let border = Color(light: 0xE9E4E1, dark: 0x3A3330)
    static let borderStrong = Color(light: 0xDDD5D1, dark: 0x4A423E)
    static let sidebar = Color(light: 0xEFEBE8, dark: 0x1F1B19)
    static let ink = Color(light: 0x282421, dark: 0xF3EFED)
    static let ink2 = Color(light: 0x6F625D, dark: 0xB5A9A3)
    static let muted = Color(light: 0x766A64, dark: 0x8A7F79)
    static let brand = Color(light: 0xD64937, dark: 0xE5604E)
    static let brandDark = Color(light: 0xB53A2B, dark: 0xF08A7A)
    static let brandWash = Color(light: 0xFBEDEA, dark: 0x3A221D)
    static let primary = Color(light: 0xB53A2B, dark: 0xD9533F)
    static let good = Color(light: 0x22704A, dark: 0x57B886)
    static let goodWash = Color(light: 0x22704A, dark: 0x57B886).opacity(0.1)
    static let bad = Color(light: 0x9F1D20, dark: 0xEF7A76)
    static let warning = Color(light: 0x9A5B08, dark: 0xE0A64A)
    static let blue = Color(light: 0x0057AE, dark: 0x6AA5EC)
    static let blueWash = Color(light: 0xE6EEF7, dark: 0x1D2A3A)
    static let violet = Color(light: 0x644A9B, dark: 0xA690E0)
    static let violetWash = Color(light: 0xEFEBF5, dark: 0x2A2436)
    static let teal = Color(light: 0x1A7471, dark: 0x4CBAB5)
    static let tealWash = Color(light: 0xE5F2F1, dark: 0x1C302F)
    static let amber = Color(light: 0xD99A2B, dark: 0xE0A64A)
    static let amberWash = Color(light: 0xF8EEDF, dark: 0x33281A)

    #if os(iOS)
    static let cardRadius: CGFloat = 12
    static let controlHeight: CGFloat = 36
    static let buttonRadius: CGFloat = 8
    #else
    /// The web's desktop sizes: 12 px cards, 32 px buttons with 6 px corners.
    static let cardRadius: CGFloat = 12
    static let controlHeight: CGFloat = 32
    static let buttonRadius: CGFloat = 6
    #endif

    /// Type. The Mac follows the web's desktop scale (13 px text and
    /// controls, 12 px labels, 15 px card titles, which its text styles run
    /// a size or two under); iPhone and iPad keep Dynamic Type's styles.
    #if os(iOS)
    static let cardTitle = Font.subheadline.weight(.semibold)
    static let tableText = Font.callout
    static let tableHead = Font.caption.weight(.semibold)
    #else
    static let tableText = Font.system(size: 13)
    static let tableHead = Font.system(size: 12, weight: .semibold)
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let text = Font.system(size: 13)
    static let strong = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 12)
    static let label = Font.system(size: 12, weight: .semibold)
    #endif

    /// The text styles the screens use: Dynamic Type's on iPhone and iPad;
    /// on the Mac the web's sizes, a size or two above the Mac's own styles.
    #if os(iOS)
    static let callout = Font.callout
    static let subheadline = Font.subheadline
    static let footnote = Font.footnote
    static let caption = Font.caption
    static let caption2 = Font.caption2
    #else
    static let callout = Font.system(size: 13)
    static let subheadline = Font.system(size: 13)
    static let footnote = Font.system(size: 12)
    static let caption = Font.system(size: 12)
    static let caption2 = Font.system(size: 11)
    #endif

    /// Quando, the workspace's display face, for titles and numbers.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom("Quando-Regular", size: size, relativeTo: style)
    }

    /// Each channel keeps its colour on every chart, list and widget, as on
    /// the web: Search blue, Email brand, Social violet, Referral teal,
    /// Paid amber, Direct ink. `channel` is the API's name for it.
    static func channel(_ channel: String?) -> (color: Color, wash: Color) {
        switch channel {
        case "Search": (blue, blueWash)
        case "Email": (brand, brandWash)
        case "Social": (violet, violetWash)
        case "Referral": (teal, tealWash)
        case "Paid": (amber, amberWash)
        case "AI assistants": (muted, subtle)
        case "Within the site": (borderStrong, subtle)
        default: (ink2, subtle)
        }
    }
}

extension Color {
    /// One colour for light and one for dark, following the system.
    init(light: UInt32, dark: UInt32) {
        #if os(iOS)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
        #else
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light) })
        #endif
    }
}

#if os(iOS)
private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// One of the workspace's icons (Lucide, 2 pt stroke at 24), tinted by the
/// foreground style. SF Symbols stay for system affordances only.
struct Icon: View {
    let name: String
    var size: CGFloat = 16

    init(_ name: String, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image("Icons/\(name)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A label with one of the workspace's icons. On the Mac it is drawn at
/// the web's 16 pt: an asset in `Label(_:image:)` keeps its 24 pt size in a
/// custom button style, twice the height of the text beside it.
struct IconLabel: View {
    let title: String
    let icon: String

    init(_ title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        #if os(macOS)
        Label { Text(title) } icon: { Icon(icon, size: 16) }
        #else
        Label(title, image: "Icons/\(icon)")
        #endif
    }
}

/// A white card with a warm 1 pt border, the workspace's container.
struct CardStyle: ViewModifier {
    var padding: CGFloat = 16
    var selected = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? Theme.brandWash.opacity(0.6) : Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(selected ? Theme.brand : Theme.border, lineWidth: selected ? 1.5 : 1))
    }
}

extension View {
    func card(padding: CGFloat = 16, selected: Bool = false) -> some View {
        modifier(CardStyle(padding: padding, selected: selected))
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

/// "+12.4%" in green, "−2.1%" in red; "vs 1,272" after it when there is room.
struct ChangeLabel: View {
    let change: AnalyticoKit.Format.Change
    var versus: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Text(change.text)
                .foregroundStyle(change.direction == .up ? Theme.good : change.direction == .down ? Theme.bad : Theme.ink2)
                .fontWeight(.semibold)
            if !versus.isEmpty { Text(versus).foregroundStyle(Theme.muted) }
        }
        .font(Theme.caption)
        .monospacedDigit()
        .lineLimit(1)
    }
}
