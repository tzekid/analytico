import AnalyticoKit
import SwiftUI

/// A report's data and how its last load went. A failed refresh keeps the
/// numbers on screen and says since when they are.
struct Loaded<Value> {
    var value: Value?
    var failure: String?
    var loadedAt: Date?
    var stale: Date?

    mutating func apply(_ result: Result<Value, Error>?, problem: (Error) -> String = Loaded.problem) {
        switch result {
        case .success(let value):
            self.value = value
            failure = nil
            stale = nil
            loadedAt = .now
        case .failure(let error):
            if value == nil { failure = problem(error) } else { stale = loadedAt }
        case nil:
            break
        }
    }

    static func problem(_ error: Error) -> String {
        if case ClientError.server(_, "session_mode_required") = error { return "This report needs visits, which Lite mode doesn’t record. Switch the site to Session or Full in the workspace." }
        return "Check the connection and pull to try again."
    }
}

/// Runs a load; nil when it was cancelled (the view changed or went away).
@MainActor
func fetch<T>(_ work: () async throws -> T) async -> Result<T, Error>? {
    do {
        return .success(try await work())
    } catch is CancellationError {
        return nil
    } catch let error as URLError where error.code == .cancelled {
        return nil
    } catch {
        return .failure(error)
    }
}

/// A card with a title row: the title, and a note or link on the right.
struct SectionCard<Aside: View, Content: View>: View {
    let title: String
    var subtitle: String?
    var padding: CGFloat = 16
    @ViewBuilder var aside: Aside
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.cardTitle).foregroundStyle(Theme.ink)
                    if let subtitle { Text(subtitle).font(Theme.footnote).foregroundStyle(Theme.ink2) }
                }
                Spacer(minLength: 8)
                aside.font(Theme.caption).foregroundStyle(Theme.muted)
            }
            content
        }
        .card(padding: padding)
    }
}

extension SectionCard where Aside == EmptyView {
    init(title: String, subtitle: String? = nil, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, padding: padding, aside: { EmptyView() }, content: content)
    }
}

/// A headline number: label and change, then the value in Quando. On iPhone
/// the change sits beside the label; on Mac and iPad it goes under the
/// value with what it is compared with.
struct MetricCard: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let label: String
    let value: String
    var change: Format.Change?
    var versus: String = ""
    var selected = false
    /// A line under the value when there is no change to show ("0 new this period").
    var note: String?

    // The web's .metric on the Mac: a 12 px semibold label over a 28 px value.
    #if os(macOS)
    private var labelFont: Font { Theme.label }
    private let valueSize: CGFloat = 28
    #else
    private var labelFont: Font { sizeClass == .compact ? .footnote : .subheadline }
    private let valueSize: CGFloat = 30
    #endif

    var body: some View {
        Group {
            if sizeClass == .compact {
                // iPhone: the change beside the label while both fit; under the
                // value once they don't, so values in a row stay level.
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            labelText.fixedSize()
                            Spacer(minLength: 4)
                            if let change, !change.text.isEmpty { ChangeLabel(change: change).fixedSize() }
                        }
                        valueText
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        labelText
                        valueText
                        if let change, !change.text.isEmpty { ChangeLabel(change: change) }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    labelText
                    valueText
                    if let change, !change.text.isEmpty {
                        ChangeLabel(change: change, versus: versus)
                    } else {
                        Text(note ?? " ").font(Theme.caption).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
            }
        }
        .card(padding: 14, selected: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var labelText: some View {
        Text(label).font(labelFont).foregroundStyle(Theme.ink2).lineLimit(1)
    }

    private var valueText: some View {
        Text(value)
            .font(Theme.display(sizeClass == .compact ? 28 : valueSize, relativeTo: .title))
            .foregroundStyle(Theme.ink)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.55)
    }
}

/// Two columns on iPhone, four across on iPad and Mac.
struct MetricGrid<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewBuilder var content: Content

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: sizeClass == .compact ? 10 : 16, alignment: .top), count: sizeClass == .compact ? 2 : 4)
        LazyVGrid(columns: columns, spacing: sizeClass == .compact ? 10 : 16) { content }
    }
}

/// A row whose wash bar shows its share; the left rule carries its colour
/// (a source's channel, for instance).
struct ShareRow: View {
    let title: String
    var detail: String?
    let value: String
    var share: Double
    var color: Color = Theme.brand
    var wash: Color = Theme.brandWash
    var rule = true

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).font(Theme.caption).foregroundStyle(Theme.ink2).lineLimit(1) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, detail == nil ? 7 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        if rule { Rectangle().fill(color).frame(width: 3) }
                        wash
                    }
                    .frame(width: max(geometry.size.width * min(max(share, 0), 1), rule ? 40 : 0))
                    .clipShape(.rect(cornerRadius: 6))
                }
            }
            Text(value).monospacedDigit().foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row with a meter under the name, as for countries: code, name, bar, share.
struct MeterRow: View {
    var code: String?
    let title: String
    let value: String
    let share: Double

    var body: some View {
        HStack(spacing: 12) {
            if let code {
                Text(code).font(Theme.caption2.weight(.semibold)).foregroundStyle(Theme.ink2)
                    .frame(width: 28, height: 22)
                    .background(Theme.subtle, in: .rect(cornerRadius: 5))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).foregroundStyle(Theme.ink).lineLimit(1)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.subtle)
                        Capsule().fill(Theme.brand).frame(width: geometry.size.width * min(max(share, 0), 1))
                    }
                }
                .frame(height: 4)
            }
            Text(value).monospacedDigit().foregroundStyle(Theme.ink).frame(minWidth: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A plain row: title with a detail line, a number on the right.
struct ValueRow: View {
    let title: String
    var detail: String?
    let value: String
    var note: String?
    var noteColor: Color = Theme.muted

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.ink).lineLimit(2)
                if let detail { Text(detail).font(Theme.caption).foregroundStyle(Theme.ink2).lineLimit(1) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).monospacedDigit().foregroundStyle(Theme.ink)
                if let note { Text(note).font(Theme.caption.weight(.semibold)).foregroundStyle(noteColor).monospacedDigit() }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A state that names itself: the workspace's illustration, what happened,
/// one primary way out and a quiet second one.
struct StageView: View {
    let art: String
    let title: String
    let text: String
    var primary: (String, () -> Void)?
    var secondary: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if art == "bars" { EmptyBars() } else { Image("Art/\(art)").resizable().scaledToFit() }
            }
            .frame(width: 200, height: 120)
            .accessibilityHidden(true)
            Text(title).font(Theme.display(art == "bars" ? 20 : 22, relativeTo: .title2)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            // Markdown, for `code` as the workspace shows it.
            Text(LocalizedStringKey(text)).font(Theme.subheadline).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
            if let primary {
                #if os(macOS)
                Button(primary.0, action: primary.1).buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
                #else
                Button(primary.0, action: primary.1).buttonStyle(PrimaryButtonStyle(wide: true)).frame(maxWidth: 300).padding(.top, 8)
                #endif
            }
            if let secondary {
                Button(secondary.0, action: secondary.1).buttonStyle(.plain).font(Theme.callout.weight(.medium)).foregroundStyle(Theme.brandDark)
            }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .card()
    }
}

/// The workspace's "nothing in this period" art: four rising bars, the last in brand.
struct EmptyBars: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 200, size.height / 120)
            func bar(_ x: CGFloat, _ y: CGFloat, _ height: CGFloat, _ color: Color) {
                context.fill(Path(roundedRect: CGRect(x: x * scale, y: y * scale, width: 24 * scale, height: height * scale), cornerRadius: 5 * scale), with: .color(color))
            }
            bar(20, 70, 34, Theme.subtle)
            bar(56, 52, 52, Theme.subtle)
            bar(92, 34, 70, Theme.brandWash)
            bar(128, 18, 86, Theme.brand.opacity(0.85))
            var base = Path()
            base.move(to: CGPoint(x: 14 * scale, y: 108 * scale))
            base.addLine(to: CGPoint(x: 186 * scale, y: 108 * scale))
            context.stroke(base, with: .color(Theme.border), style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
        }
    }
}

/// Loading or failed, in place of a report's cards.
struct LoadingOrProblem: View {
    var failure: String?
    var title = "This report didn’t load"

    var body: some View {
        if let failure {
            Problem(title: title, detail: failure)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        }
    }
}

/// Change in points for shares: "+4 pts", "−0.3 pts".
func pointsChange(_ now: Double?, _ before: Double?, decimals: Int = 0) -> Format.Change? {
    guard let now, let before else { return nil }
    let delta = (now - before) * 100
    let shown = abs(delta).formatted(.number.precision(.fractionLength(decimals)))
    let unit = shown == "1" ? "pt" : "pts"
    if delta.magnitude < (decimals == 0 ? 0.5 : 0.05) { return .init(text: "0 pts", direction: .flat) }
    return .init(text: "\(delta > 0 ? "+" : "−")\(shown) \(unit)", direction: delta > 0 ? .up : .down)
}

/// "4,280 views", the share of the period's total as a fraction.
func share(_ part: Double, _ whole: Double) -> Double {
    whole == 0 ? 0 : part / whole
}

/// "Tap" on a touch screen, "Click" with a pointer: "Click to filter".
#if os(macOS)
let press = "Click"
#else
let press = "Tap"
#endif

/// "1 order", "18 orders".
func plural(_ count: Int, _ noun: String) -> String {
    "\(Format.count(count)) \(noun)\(count == 1 ? "" : "s")"
}

// MARK: - Tables (Mac, iPad)

/// The workspace's table: a card with a header band, rows split by
/// hairlines and a footer line, at the web's sizes (13 px rows, 12 px heads).
struct TableCard<Top: View, Head: View, Rows: View>: View {
    var footer: String?
    var hint: String?
    @ViewBuilder var top: Top
    @ViewBuilder var head: Head
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            HStack(spacing: 0) { head }
                .font(Theme.tableHead)
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(Theme.canvas)
            rows
            if footer != nil || hint != nil {
                HStack {
                    if let footer { Text(footer) }
                    Spacer(minLength: 12)
                    if let hint { Text(hint) }
                }
                .font(Theme.tableText)
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }
}

extension TableCard where Top == EmptyView {
    init(footer: String? = nil, hint: String? = nil, @ViewBuilder head: () -> Head, @ViewBuilder rows: () -> Rows) {
        self.init(footer: footer, hint: hint, top: { EmptyView() }, head: head, rows: rows)
    }
}

/// A column head; a sortable one names its order with an arrow.
struct TableHead: View {
    let title: String
    var sorted = false
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 3) {
                Text(title)
                if sorted { Image(systemName: "arrow.down").font(Theme.caption2.weight(.bold)) }
            }
            .foregroundStyle(sorted ? Theme.ink : Theme.ink2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

/// A table row: 13 px, a hairline above, the brand wash when selected or under the pointer.
struct TableRowStyle: ViewModifier {
    var selected = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(Theme.tableText)
            .monospacedDigit()
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(selected || hovering ? Theme.brandWash : .clear)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            .contentShape(.rect)
            .onHover { hovering = $0 }
    }
}

extension View {
    func tableRow(selected: Bool = false) -> some View { modifier(TableRowStyle(selected: selected)) }
}

/// A change as the workspace's tables show it: a small tinted badge.
struct ChangeBadge: View {
    let change: Format.Change

    var body: some View {
        let up = change.direction == .up, down = change.direction == .down
        Text(change.text)
            .font(Theme.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(up ? Theme.good : down ? Theme.bad : Theme.ink2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(up ? Theme.goodWash : down ? Theme.bad.opacity(0.09) : Theme.subtle, in: .rect(cornerRadius: 5))
    }
}

/// The filter field above a table, as on the workspace: a bordered field with a search icon.
struct TableFilterField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Icon("search", size: 15).foregroundStyle(Theme.muted)
            TextField(prompt, text: $text).textFieldStyle(.plain)
        }
        .font(Theme.tableText)
        .padding(.horizontal, 12)
        .frame(width: 320, height: 36)
        .background(Theme.surface, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .padding(16)
    }
}
