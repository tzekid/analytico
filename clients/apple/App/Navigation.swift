import AnalyticoKit
import SwiftUI

/// A report the apps show, grouped as in the sidebar (Mac, iPad) and More (iPhone).
enum Screen: String, CaseIterable, Identifiable, Hashable {
    case overview, live, pages, paths, sources, campaigns, search, audience, events, errors, performance, revenue, retention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .live: "Live"
        case .pages: "Pages"
        case .paths: "Paths"
        case .sources: "Acquisition"
        case .campaigns: "Campaigns"
        case .search: "Site search"
        case .audience: "Audience"
        case .events: "Events & goals"
        case .errors: "Errors"
        case .performance: "Performance"
        case .revenue: "Revenue"
        case .retention: "Retention"
        }
    }

    /// The iPhone tab bar's shorter name, as on the web's phone tab bar.
    var tabTitle: String { self == .sources ? "Sources" : title }

    /// The workspace icon (`Icons/<name>`).
    var icon: String {
        switch self {
        case .overview: "overview"
        case .live: "live"
        case .pages: "pages"
        case .paths: "paths"
        case .sources: "sources"
        case .campaigns: "megaphone"
        case .search: "search"
        case .audience: "audience"
        case .events: "events"
        case .errors: "bug"
        case .performance: "performance"
        case .revenue: "revenue"
        case .retention: "retention"
        }
    }

    /// The workspace page with the same report, for "Open in the workspace".
    var workspacePage: String? {
        switch self {
        case .overview: nil
        case .live: "live"
        case .pages: "pages"
        case .paths: "sessions"
        case .sources, .campaigns: "acquisition"
        case .search: "pages"
        case .audience: "audience"
        case .events: "events"
        case .errors: "errors"
        case .performance: "performance"
        case .revenue: "revenue"
        case .retention: "retention"
        }
    }

    /// What the report is, before its period in the subtitle, as on the web.
    var lead: String? {
        switch self {
        case .sources: "Where visitors come from, and what campaigns earn"
        case .campaigns: "What each campaign brings"
        case .search: "What visitors searched for on the site"
        case .audience: "Who visits"
        case .errors: "JavaScript errors visitors ran into, grouped"
        case .performance: "Real-user measurements"
        case .revenue: "Orders and products"
        case .paths: "Where visitors go from each page"
        default: nil
        }
    }

    /// Live and Retention cover their own period and say so instead.
    var fixedPeriod: (text: String, why: String)? {
        switch self {
        case .live: ("Right now · the last 5 minutes", "Live shows the last five minutes and updates by itself.")
        case .retention: ("Last 8 weeks · updated daily", "Retention follows each week’s new visitors for 8 weeks, so it doesn’t use the period.")
        default: nil
        }
    }

    /// As in the workspace's sidebar; campaigns are a tab of Acquisition there too.
    static let groups: [(String, [Screen])] = [
        ("", [.overview, .live]),
        ("Traffic", [.pages, .paths, .sources, .search, .audience]),
        ("Behaviour", [.events]),
        ("Customers", [.revenue, .retention]),
        ("Quality", [.performance, .errors]),
    ]

    /// iPhone: the screens with a tab of their own; More lists the rest.
    static let tabs: [Screen] = [.overview, .pages, .sources, .live]
}

/// One site open in a window: the period and filters every screen shares,
/// and what is selected or presented.
@MainActor @Observable
final class SiteState {
    let client: Client
    let site: Site
    var view = ViewState()
    /// Mac and iPad: the sidebar's selection.
    var screen: Screen = .overview
    /// iPhone: the selected tab (nil is More) and the screens pushed under More.
    var tab: Screen? = .overview
    var more: [Screen] = []
    /// The page shown in the inspector (Mac, iPad) or the page sheet (iPhone).
    var page: String?
    /// iPhone: the page sheet opens at half height.
    var pageDetent: PresentationDetent = .medium
    var addingNote = false
    /// People online now and the newest page view, from the live stream.
    var online: Int?
    var last: Int?

    init(client: Client, site: Site) {
        self.client = client
        self.site = site
    }

    /// Opens a screen wherever this layout keeps it.
    /// The workspace's settings for this site, where its tracking mode is chosen.
    var siteSettingsURL: URL {
        client.instance.origin.appending(path: "settings/sites").appending(queryItems: [URLQueryItem(name: "site", value: site.slug)])
    }

    func show(_ target: Screen) {
        screen = target
        if Screen.tabs.contains(target) {
            tab = target
        } else {
            tab = nil
            more = [target]
        }
    }

    /// Opens a page's details: a sheet on iPhone, beside Pages on iPad and Mac.
    func inspect(_ path: String) {
        page = path
        screen = .pages
    }

    /// Adds a filter, replacing one on the same dimension. Said in a notice
    /// with Undo, since its chip is at the top, often out of sight.
    func filter(_ dimension: String, _ value: String, negated: Bool = false, label: String? = nil) {
        let before = view
        view.filters.removeAll { $0.dimension == dimension }
        view.filters.append(.init(dimension: dimension, value: value, negated: negated))
        notice = Notice(text: "Every report now shows \(Labels.dimension(dimension).lowercased()) \(negated ? "is not" : "is") \(label ?? Labels.value(value, dimension: dimension))", undo: before)
    }

    /// A short message at the bottom of the window, with a way back.
    struct Notice: Equatable {
        let id = UUID()
        var text: String
        var undo: ViewState
    }
    var notice: Notice?

    func workspaceURL(_ screen: Screen) -> URL {
        view.workspaceURL(origin: client.instance.origin, site: site.slug, page: screen.workspacePage)
    }
}

/// The signed-in app: the chosen site, or the list to choose from.
struct SitesRoot: View {
    @Environment(AppModel.self) private var model
    let client: Client

    var body: some View {
        if let slug = model.selectedSite, let site = model.sites.first(where: { $0.slug == slug }) {
            SiteRoot(client: client, site: site)
                .id(site.slug)
        } else {
            SitesList(client: client)
        }
    }
}

/// One site: a tab bar on iPhone, a sidebar on iPad and Mac.
struct SiteRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var state: SiteState

    init(client: Client, site: Site) {
        _state = State(initialValue: SiteState(client: client, site: site))
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                PhoneShell()
            } else {
                SplitShell()
            }
        }
        .overlay(alignment: .bottom) { NoticeBar() }
        .animation(.easeOut(duration: 0.2), value: state.notice)
        .environment(state)
        .focusedSceneValue(\.siteState, state)
        .tint(Theme.brand)
        .sheet(isPresented: $state.addingNote) {
            AddNoteSheet(client: state.client, site: state.site)
        }
        .task { await followLive() }
        .onChange(of: model.pendingLink, initial: true) { _, link in
            guard let link else { return }
            state.view = ViewState(url: link)
            let page = link.pathComponents.filter { $0 != "/" }.dropFirst().first
            state.show(Screen.allCases.first { $0.workspacePage == page && $0 != .search } ?? .overview)
            // A workspace link to a page's details opens them here too.
            state.page = page == "pages" ? URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value : nil
            model.pendingLink = nil
        }
    }

    /// People online now, for the sidebar's Live row and the Live tab.
    private func followLive() async {
        while !Task.isCancelled {
            do {
                for try await update in await state.client.live(site: state.site.slug) {
                    state.online = update.online
                    if update.last != state.last { state.last = update.last }
                }
            } catch is CancellationError {
                return
            } catch ClientError.signedOut {
                model.signOut(ended: true)
                return
            } catch {}
            try? await Task.sleep(for: .seconds(30))
        }
    }
}

// MARK: - iPhone

/// Overview · Pages · Sources · Live · More, in the floating glass tab bar.
struct PhoneShell: View {
    @Environment(SiteState.self) private var state

    var body: some View {
        @Bindable var state = state
        TabView(selection: $state.tab) {
            ForEach(Screen.tabs) { screen in
                Tab(screen.tabTitle, image: "Icons/\(screen.icon)", value: Optional(screen)) {
                    NavigationStack {
                        ScreenView(screen: screen)
                            .phoneRootBar()
                    }
                }
            }
            Tab("More", image: "Icons/more", value: Screen?.none) {
                NavigationStack(path: $state.more) {
                    MoreView()
                        .phoneRootBar()
                        .navigationDestination(for: Screen.self) { screen in
                            ScreenView(screen: screen)
                                .pushedBar()
                        }
                }
            }
        }
        // Page details open at half height over the list, which stays usable:
        // another row swaps the details in place; pull up for all of them,
        // down to close.
        .sheet(isPresented: Binding(get: { state.page != nil }, set: { if !$0 { state.page = nil } })) {
            if let page = state.page {
                PageDetail(path: page)
                    .presentationDetents([.medium, .large], selection: $state.pageDetent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationContentInteraction(.resizes)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Theme.canvas)
            }
        }
        .onChange(of: state.page == nil) { _, closed in
            if closed { state.pageDetent = .medium }
        }
    }
}

extension View {
    /// Tab roots: the site switcher and Settings float above the page.
    func phoneRootBar() -> some View {
        modifier(PhoneRootBar())
    }

    /// Screens opened from More: back, the site's name, and the actions.
    func pushedBar() -> some View {
        modifier(PushedBar())
    }
}

private struct PhoneRootBar: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var switching = false
    @State private var settings = false

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { switching = true } label: { SiteSwitcherLabel() }
                        .accessibilityLabel("Switch website")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Icon("settings", size: 20).foregroundStyle(Theme.ink) }
                        .accessibilityLabel("Settings")
                }
            }
            #endif
            .sheet(isPresented: $switching) {
                SiteSwitcherSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Theme.canvas)
            }
            .sheet(isPresented: $settings) {
                SettingsSheet()
            }
    }
}

private struct PushedBar: ViewModifier {
    @Environment(SiteState.self) private var state

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(state.site.name)
    }
}

/// The site in the header: its mark, name and host; opens the switcher.
struct SiteSwitcherLabel: View {
    @Environment(SiteState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            Mark(size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.site.name).font(Theme.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(state.site.host).font(Theme.caption).foregroundStyle(Theme.ink2)
            }
            .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.ink2)
        }
        .padding(.trailing, 4)
    }
}

/// Every report without a tab of its own, grouped as in the sidebar.
struct MoreView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("More").font(Theme.display(30, relativeTo: .largeTitle)).foregroundStyle(Theme.ink)
                    .padding(.bottom, 4)
                ForEach(Screen.groups, id: \.0) { group in
                    let rest = group.1.filter { !Screen.tabs.contains($0) }
                    if !rest.isEmpty {
                        if !group.0.isEmpty {
                            Text(group.0.uppercased()).font(Theme.caption.weight(.semibold)).tracking(0.6).foregroundStyle(Theme.ink2)
                                .padding(.leading, 14).padding(.top, 10)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(rest.enumerated()), id: \.element) { index, screen in
                                if index > 0 { Divider().padding(.leading, 48) }
                                NavigationLink(value: screen) {
                                    HStack(spacing: 14) {
                                        Icon(screen.icon, size: 20).foregroundStyle(Theme.ink2)
                                        Text(screen == .audience ? "Audience · countries and devices" : screen.title).foregroundStyle(Theme.ink)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(Theme.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 48)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.canvas)
    }
}

// MARK: - Mac and iPad

/// The floating sidebar and the selected report.
struct SplitShell: View {
    @Environment(SiteState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
                #if os(macOS)
                .toolbar(removing: .sidebarToggle)
                #endif
        } detail: {
            NavigationStack {
                ScreenView(screen: state.screen)
                    #if os(macOS)
                    .toolbar(removing: .title)
                    #else
                    .toolbar(.hidden, for: .navigationBar)
                    #endif
            }
        }
        #if os(macOS)
        .toolbar(removing: .sidebarToggle)
        .toolbar(.hidden, for: .windowToolbar)
        #endif
    }
}

/// Site switcher card, "Go to a report…", the groups, Settings.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(SiteState.self) private var state
    @State private var query = ""
    @State private var switching = false
    @State private var settings = false
    @FocusState private var searching: Bool
    /// The report list takes ↑ and ↓ once a row was clicked, as a Mac sidebar does.
    @FocusState private var listFocused: Bool

    private var matches: [(String, [Screen])] {
        let words = query.trimmingCharacters(in: .whitespaces)
        if words.isEmpty { return Screen.groups }
        return Screen.groups.map { ($0.0, $0.1.filter { $0.title.localizedStandardContains(words) }) }.filter { !$0.1.isEmpty }
    }

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 0) {
            Button { switching = true } label: {
                HStack(spacing: 10) {
                    SiteAvatar(name: state.site.name)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.site.name).font(rowStrong).foregroundStyle(Theme.ink)
                        Text(state.site.host).font(rowSmall).foregroundStyle(Theme.ink2)
                    }
                    .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.surface, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch website, \(state.site.name)")
            .popover(isPresented: $switching, arrowEdge: .bottom) {
                SiteSwitcherSheet().frame(width: 340)
            }
            HStack(spacing: 8) {
                Icon("search", size: 14).foregroundStyle(Theme.muted)
                TextField("Go to a report…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit {
                        if let first = matches.first?.1.first { state.screen = first }
                        query = ""
                    }
                Text("⌘K").font(Theme.caption2.weight(.semibold)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Theme.subtle, in: .rect(cornerRadius: 4))
            }
            .font(rowText)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Theme.surface, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .padding(.top, 10)
            .background(Button("") { searching = true }.keyboardShortcut("k").opacity(0))
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(matches, id: \.0) { group in
                        if !group.0.isEmpty {
                            Text(group.0.uppercased()).font(groupFont).tracking(0.66).foregroundStyle(Theme.muted)
                                .padding(.leading, 10).padding(.top, 14).padding(.bottom, 6)
                        }
                        ForEach(group.1) { screen in
                            SidebarRow(screen: screen, selected: state.screen == screen, online: screen == .live ? state.online : nil) {
                                state.screen = screen
                                listFocused = true
                            }
                        }
                    }
                }
                .padding(.top, 12)
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { step(1) }
                .onKeyPress(.upArrow) { step(-1) }
            }
            .scrollIndicators(.never)
            Divider().padding(.vertical, 8)
            settingsRow
            Text("\(state.client.instance.host)").font(Theme.caption2).foregroundStyle(Theme.muted)
                .padding(.leading, 10).padding(.top, 6)
        }
        .padding(12)
        .sheet(isPresented: $settings) { SettingsSheet() }
    }

    // The web's sidebar: 13 px site name, 12 px host, 11 px group labels.
    #if os(macOS)
    private let rowStrong = Theme.strong
    private let rowSmall = Theme.small
    private let rowText = Theme.text
    private let groupFont = Font.system(size: 11, weight: .semibold)
    #else
    private let rowStrong = Font.callout.weight(.semibold)
    private let rowSmall = Font.caption
    private let rowText = Font.callout
    private let groupFont = Font.caption2.weight(.semibold)
    #endif

    private func step(_ by: Int) -> KeyPress.Result {
        let screens = matches.flatMap(\.1)
        guard let index = screens.firstIndex(of: state.screen) else { return .ignored }
        state.screen = screens[min(max(index + by, 0), screens.count - 1)]
        return .handled
    }

    @ViewBuilder private var settingsRow: some View {
        #if os(macOS)
        SettingsLink {
            SidebarRowLabel(icon: "settings", title: "Settings", selected: false)
        }
        .buttonStyle(.plain)
        #else
        Button { settings = true } label: {
            SidebarRowLabel(icon: "settings", title: "Settings", selected: false)
        }
        .buttonStyle(.plain)
        #endif
    }
}

private struct SidebarRow: View {
    let screen: Screen
    let selected: Bool
    let online: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SidebarRowLabel(icon: screen.icon, title: screen.title, selected: selected) {
                if let online {
                    Text(Format.count(online)).font(Theme.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(online > 0 ? Theme.good : Theme.muted)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SidebarRowLabel<Trailing: View>: View {
    let icon: String
    let title: String
    let selected: Bool
    @ViewBuilder var trailing: Trailing
    // The web's .nav: 13.5 px in a 34 px row.
    #if os(macOS)
    private let rowFont = Font.system(size: 13.5)
    private let rowHeight: CGFloat = 34
    #else
    private let rowFont = Font.callout
    private let rowHeight: CGFloat = 30
    #endif

    var body: some View {
        HStack(spacing: 11) {
            Icon(icon, size: 16).foregroundStyle(selected ? Theme.brand : Theme.ink2)
            Text(title).foregroundStyle(selected ? Theme.brandDark : Theme.ink).fontWeight(selected ? .semibold : .regular)
            Spacer()
            trailing
        }
        .font(rowFont)
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(selected ? Theme.brandWash : .clear, in: .rect(cornerRadius: 7))
        .contentShape(.rect)
    }
}

extension SidebarRowLabel where Trailing == EmptyView {
    init(icon: String, title: String, selected: Bool) {
        self.init(icon: icon, title: title, selected: selected) { EmptyView() }
    }
}

/// The report for a screen.
struct ScreenView: View {
    let screen: Screen

    var body: some View {
        switch screen {
        case .overview: OverviewView()
        case .live: LiveView()
        case .pages: PagesView()
        case .paths: PathsView()
        case .sources: SourcesView()
        case .campaigns: CampaignsView()
        case .search: SiteSearchView()
        case .audience: AudienceView()
        case .events: EventsView()
        case .errors: ErrorsView()
        case .performance: PerformanceView()
        case .revenue: RevenueView()
        case .retention: RetentionView()
        }
    }
}

/// The notice above the tab bar (iPhone) or at the bottom of the window:
/// what changed, and Undo; it goes after five seconds.
struct NoticeBar: View {
    @Environment(SiteState.self) private var state
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if let notice = state.notice {
            HStack(spacing: 12) {
                Icon("filter", size: 16).foregroundStyle(Color(red: 0.48, green: 0.83, blue: 0.63))
                Text(notice.text).font(Theme.subheadline).foregroundStyle(.white).lineLimit(2)
                Spacer(minLength: 4)
                Button("Undo") {
                    state.view = notice.undo
                    state.notice = nil
                }
                .buttonStyle(.plain)
                .font(Theme.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 1, green: 0.71, blue: 0.66))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 520)
            .background(Color(light: 0x282421, dark: 0x3A3330), in: .rect(cornerRadius: 14))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .padding(.horizontal, 16)
            .padding(.bottom, sizeClass == .compact ? 92 : 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(5))
                if state.notice?.id == notice.id { withAnimation { state.notice = nil } }
            }
        }
    }
}

/// A site's initial on the brand tile, as the workspace marks a site.
struct SiteAvatar: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "·")
            .font(Theme.display(size * 0.54, relativeTo: .body))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.brand, in: .rect(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }
}
