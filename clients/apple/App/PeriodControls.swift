import AnalyticoKit
import SwiftUI

/// The period: the workspace's presets, common days, and chosen dates. The
/// label always says what is shown ("7 days", "Today", "30 Sep").
struct PeriodMenu: View {
    @Binding var view: ViewState
    let site: Site
    @State private var choosing = false

    var body: some View {
        Menu {
            Section {
                ForEach(ViewState.Period.allCases) { period in
                    Toggle(period.title, isOn: Binding(get: { !view.isCustom && view.period == period }, set: { _ in choose(period) }))
                }
            }
            Section {
                ForEach(QuickRange.allCases) { range in
                    let days = range.days()
                    Toggle(range.title, isOn: Binding(get: { view.from == days.from && view.to == days.to }, set: { _ in choose(from: days.from, to: days.to) }))
                }
                Button("Custom range…") { choosing = true }
            }
        } label: {
            Label(label, systemImage: "calendar")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("Period: \(label)")
        .sheet(isPresented: $choosing) {
            CustomRangeSheet(view: $view, site: site)
        }
    }

    private var label: String {
        if let from = view.from, let to = view.to, let wording = PeriodWording(from: from, to: to) { return wording.button }
        return view.period.short
    }

    private func choose(_ period: ViewState.Period) {
        view.from = nil
        view.to = nil
        view.period = period
    }

    private func choose(from: String, to: String) {
        view = .custom(from: from, to: to, filters: view.filters)
    }
}

enum QuickRange: String, CaseIterable, Identifiable {
    case today, yesterday, thisMonth, lastMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        }
    }

    /// Inclusive days in UTC, the instance's clock.
    func days(now: Date = .now) -> (from: String, to: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let today = calendar.startOfDay(for: now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
        switch self {
        case .today: return (Dates.iso(today), Dates.iso(today))
        case .yesterday:
            let day = today.addingTimeInterval(-86_400)
            return (Dates.iso(day), Dates.iso(day))
        case .thisMonth: return (Dates.iso(monthStart), Dates.iso(today))
        case .lastMonth:
            let end = monthStart.addingTimeInterval(-86_400)
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: end))!
            return (Dates.iso(start), Dates.iso(end))
        }
    }
}

/// From and To, limited to the days that have data; To can't come before
/// From, so there is nothing to correct afterwards.
struct CustomRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var view: ViewState
    let site: Site
    @State private var from = Date()
    @State private var to = Date()

    private var first: Date { site.firstDay.flatMap(Dates.parse) ?? Dates.today }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $from, in: first...Dates.today, displayedComponents: .date)
                DatePicker("To", selection: $to, in: from...Dates.today, displayedComponents: .date)
                Section {
                    Text("Data from \(first.formatted(Dates.style.day().month(.abbreviated).year())) to today. One day shows hours; longer ranges show days.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .environment(\.timeZone, .gmt)
            .navigationTitle("Choose dates")
            .onChange(of: from) { _, value in if to < value { to = value } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        view = .custom(from: Dates.iso(from), to: Dates.iso(to), filters: view.filters)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 260)
        .onAppear {
            from = view.from.flatMap(Dates.parse) ?? Dates.today
            to = view.to.flatMap(Dates.parse) ?? Dates.today
        }
    }
}

/// For screens that cover their own period, in place of the period menu.
struct FixedPeriod: View {
    let text: String
    let why: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: .rect(cornerRadius: 8))
            .help(why)
            .accessibilityLabel("\(text). \(why)")
    }
}
