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
                    if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(Theme.ink2) }
                }
                Spacer(minLength: 8)
                aside.font(.caption).foregroundStyle(Theme.muted)
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

    var body: some View {
        VStack(alignment: .leading, spacing: sizeClass == .compact ? 6 : 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).font(sizeClass == .compact ? .footnote : .subheadline).foregroundStyle(Theme.ink2).lineLimit(1)
                Spacer(minLength: 4)
                if sizeClass == .compact, let change, !change.text.isEmpty { ChangeLabel(change: change) }
            }
            Text(value)
                .font(Theme.display(sizeClass == .compact ? 28 : 30, relativeTo: .title))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            if sizeClass != .compact {
                if let change, !change.text.isEmpty {
                    ChangeLabel(change: change, versus: versus)
                } else {
                    Text(" ").font(.caption)
                }
            }
        }
        .card(padding: 14, selected: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                if let detail { Text(detail).font(.caption).foregroundStyle(Theme.ink2).lineLimit(1) }
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
                Text(code).font(.caption2.weight(.semibold)).foregroundStyle(Theme.ink2)
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
                if let detail { Text(detail).font(.caption).foregroundStyle(Theme.ink2).lineLimit(1) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).monospacedDigit().foregroundStyle(Theme.ink)
                if let note { Text(note).font(.caption.weight(.semibold)).foregroundStyle(noteColor).monospacedDigit() }
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
            Image("Art/\(art)").resizable().scaledToFit().frame(width: 200, height: 120).accessibilityHidden(true)
            Text(title).font(Theme.display(22, relativeTo: .title2)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            Text(text).font(.subheadline).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let primary {
                Button(primary.0, action: primary.1).buttonStyle(PrimaryButtonStyle(wide: true)).frame(maxWidth: 300).padding(.top, 8)
            }
            if let secondary {
                Button(secondary.0, action: secondary.1).buttonStyle(.plain).font(.callout.weight(.medium)).foregroundStyle(Theme.brandDark)
            }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .card()
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

/// "1 order", "18 orders".
func plural(_ count: Int, _ noun: String) -> String {
    "\(Format.count(count)) \(noun)\(count == 1 ? "" : "s")"
}
