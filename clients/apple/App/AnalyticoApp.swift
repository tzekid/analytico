import AnalyticoKit
import AppIntents
import SwiftUI

@main
struct AnalyticoApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    #else
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage("menuBar") private var menuBar = true
    #endif
    private var model: AppModel { delegate.model }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .onOpenURL { url in
                    #if DEBUG && os(macOS)
                    if DebugSnapshot.handle(url) { return }
                    #endif
                    model.open(url)
                }
                // Links (widgets, notifications, the workspace) go to the open
                // window instead of opening another each time.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .tint(Theme.brand)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sign Out") { model.signOut() }
                    .disabled(model.client == nil)
            }
            GoCommands()
        }
        #endif
        #if os(macOS)
        Settings {
            SettingsWindow().environment(model)
        }
        MenuBarExtra(isInserted: $menuBar) {
            MenuBarPanel().environment(model)
        } label: {
            Label(model.online.map { "\($0)" } ?? "", systemImage: "chart.bar.fill")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

#if DEBUG && os(macOS)
/// Development only: `analytico://debug/snapshot?name=pages` renders the main
/// window and posts it as a PNG to a collector on 127.0.0.1:8125, to check
/// screens side by side with the workspace without screen-recording access;
/// `analytico://debug/appearance?mode=dark` switches the app's appearance and
/// `analytico://debug/size?w=1000&h=760` resizes the window.
@MainActor enum DebugSnapshot {
    static func handle(_ url: URL) -> Bool {
        guard url.host == "debug" else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // analytico://debug/appearance?mode=dark|light|system
        if url.path == "/appearance" {
            let mode = query.first { $0.name == "mode" }?.value
            NSApp.appearance = mode == "dark" ? NSAppearance(named: .darkAqua) : mode == "light" ? NSAppearance(named: .aqua) : nil
            return true
        }
        // analytico://debug/size?w=1000&h=760
        if url.path == "/size", let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) {
            let width = Double(query.first { $0.name == "w" }?.value ?? "") ?? 1280, height = Double(query.first { $0.name == "h" }?.value ?? "") ?? 800
            window.setContentSize(NSSize(width: width, height: height))
            return true
        }
        let name = query.first { $0.name == "name" }?.value ?? "window"
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return true }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]), let target = URL(string: "http://127.0.0.1:8125/\(name).png") else { return true }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        URLSession.shared.uploadTask(with: request, from: png).resume()
        return true
    }
}
#endif

/// "How many visitors today on shop?" from Siri, Spotlight and Shortcuts.
struct AnalyticoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: VisitorsTodayIntent(), phrases: [
            "Visitors today in \(.applicationName)",
            "How many visitors on \(\.$site) in \(.applicationName)",
        ], shortTitle: "Visitors today", systemImageName: "chart.bar")
    }
}

extension FocusedValues {
    /// The site open in the focused window, for the Go menu.
    @Entry var siteState: SiteState?
    /// Reloads the report in the focused window, for View → Refresh (⌘R).
    @Entry var reload: ReloadAction?
}

/// Equal by screen: a re-render with a new closure is not a change, so
/// publishing it can't loop.
struct ReloadAction: Equatable {
    let screen: Screen
    let run: () async -> Void

    static func == (left: ReloadAction, right: ReloadAction) -> Bool { left.screen == right.screen }
}

#if os(macOS)
/// Go: ⌘1–⌘9 open reports in sidebar order; [ and ] shorten or lengthen the period.
struct GoCommands: Commands {
    @FocusedValue(\.siteState) private var state
    @FocusedValue(\.reload) private var reload

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Refresh") { if let reload { Task { await reload.run() } } }
                .keyboardShortcut("r")
                .disabled(reload == nil)
            Divider()
        }
        CommandMenu("Go") {
            let screens = Screen.groups.flatMap(\.1)
            ForEach(Array(screens.prefix(9).enumerated()), id: \.element) { index, screen in
                Button(screen.title) { state?.screen = screen }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button("Shorter Period") { step(-1) }.keyboardShortcut("[", modifiers: [])
            Button("Longer Period") { step(1) }.keyboardShortcut("]", modifiers: [])
        }
    }

    private func step(_ by: Int) {
        guard let state else { return }
        let periods = ViewState.Period.allCases
        let index = state.view.isCustom ? 1 : periods.firstIndex(of: state.view.period) ?? 1
        state.view.from = nil
        state.view.to = nil
        state.view.period = periods[min(max(index + by, 0), periods.count - 1)]
    }
}

/// The menu bar: people online now on the open site and its last half hour,
/// today's visitors on every site, and Open · Settings · Quit.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var minutes: [Int] = []
    @State private var today: (visitors: Double, change: Format.Change)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.client == nil {
                Text("Not signed in").foregroundStyle(Theme.ink2).padding(16)
            } else if let slug = model.selectedSite, let site = model.sites.first(where: { $0.slug == slug }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(site.name).font(Theme.subheadline.weight(.semibold)).foregroundStyle(Theme.ink2)
                        Spacer()
                        Circle().fill((model.online ?? 0) > 0 ? Theme.good : Theme.muted).frame(width: 8, height: 8)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Format.count(model.online ?? 0)).font(Theme.display(40, relativeTo: .largeTitle)).foregroundStyle(Theme.ink).contentTransition(.numericText())
                        Text("online now").foregroundStyle(Theme.ink2)
                    }
                    let busiest = max(1, minutes.max() ?? 1)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(minutes.enumerated()), id: \.offset) { index, count in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(count == 0 ? Theme.border : index == minutes.count - 1 ? Theme.brand.opacity(0.45) : Theme.brand)
                                .frame(height: count == 0 ? 3 : max(5, 44 * Double(count) / Double(busiest)))
                        }
                    }
                    .frame(height: 44, alignment: .bottom)
                    if let today {
                        Text("\(Format.count(Int(today.visitors))) visitors today\(today.change.text.isEmpty ? "" : " · \(today.change.text) vs yesterday by now")")
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(today.change.direction == .down ? Theme.bad : Theme.good)
                    }
                }
                .padding(16)
                Divider().padding(.horizontal, 16)
                Text("YOUR SITES · TODAY").font(Theme.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(Theme.muted).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                ForEach(model.sites) { other in
                    Button { model.selectedSite = other.slug } label: {
                        HStack(spacing: 10) {
                            SiteBadge(site: other, size: 24)
                            Text(other.name).fontWeight(other.slug == slug ? .semibold : .regular).foregroundStyle(other.slug == slug ? Theme.brandDark : Theme.ink)
                            Spacer()
                            Text(Format.count(other.today.visitors)).monospacedDigit().foregroundStyle(Theme.ink)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(other.slug == slug ? Theme.brandWash : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                }
            } else {
                Text("Choose a site in the main window.").foregroundStyle(Theme.ink2).padding(16)
            }
            Divider().padding(.horizontal, 16).padding(.top, 8)
            VStack(spacing: 0) {
                menuRow("Open Analytico", "⌘O") {
                    NSApp.activate()
                    if NSApp.windows.allSatisfy({ !$0.isVisible || $0.level != .normal }) { openWindow(id: "main") }
                }
                .keyboardShortcut("o")
                SettingsLink { menuLabel("Settings…", "⌘,") }.buttonStyle(.plain)
                menuRow("Quit Analytico", "⌘Q") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
        .frame(width: 320)
        .background(Theme.canvas)
        .task(id: model.selectedSite) { await load() }
        .task(id: model.online) { await loadMinutes() }
    }

    private func menuRow(_ title: String, _ shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { menuLabel(title, shortcut) }.buttonStyle(.plain)
    }

    private func menuLabel(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.ink)
            Spacer()
            Text(shortcut).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .contentShape(.rect)
    }

    private func load() async {
        await model.loadSites()
        guard let client = model.client, let slug = model.selectedSite else { return }
        let day = Dates.iso(Dates.today)
        if let totals = try? await client.report("overview", site: slug, view: .custom(from: day, to: day)).rows.first {
            let now = totals["visitor_days"]?.number ?? 0
            today = (now, Format.change(now, totals["previous_visitor_days"]?.number ?? 0))
        }
        await loadMinutes()
    }

    private func loadMinutes() async {
        guard let client = model.client, let slug = model.selectedSite else { return }
        if let rows = try? await client.report("minutes", site: slug, view: ViewState(period: .day)).rows {
            minutes = rows.map { Int($0["page_views"]?.number ?? 0) }
        }
    }
}
#endif

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .setup:
                if let host = model.signedOutFrom {
                    SignedOutView(host: host)
                } else {
                    SetupView()
                }
            case .signedIn(let client):
                SitesRoot(client: client)
                    .task { await model.loadSites() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 960, minHeight: 640)
        #endif
    }
}
