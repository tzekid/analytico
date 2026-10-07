import AnalyticoKit
import SwiftUI

/// What a screen in the sidebar shows.
enum Screen: String, CaseIterable, Identifiable, Hashable {
    case overview, live, pages, sources, campaigns, search, countries, devices, events, goals, errors, performance, revenue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .live: "Live"
        case .pages: "Pages"
        case .sources: "Sources"
        case .campaigns: "Campaigns"
        case .search: "Site search"
        case .countries: "Countries"
        case .devices: "Devices"
        case .events: "Events"
        case .goals: "Goals"
        case .errors: "Errors"
        case .performance: "Performance"
        case .revenue: "Revenue"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .live: "dot.radiowaves.left.and.right"
        case .pages: "doc.text"
        case .sources: "arrow.triangle.branch"
        case .campaigns: "megaphone"
        case .search: "magnifyingglass"
        case .countries: "globe.europe.africa"
        case .devices: "laptopcomputer.and.iphone"
        case .events: "bolt"
        case .goals: "flag"
        case .errors: "exclamationmark.triangle"
        case .performance: "gauge.with.dots.needle.67percent"
        case .revenue: "cart"
        }
    }

    /// The workspace page with the same report, for "Open in workspace".
    var workspacePage: String? {
        switch self {
        case .overview: nil
        case .live: "sessions"
        case .pages, .search: "pages"
        case .sources, .campaigns: "acquisition"
        case .countries, .devices: "audience"
        case .events, .goals: "events"
        case .errors: "errors"
        case .performance: "performance"
        case .revenue: "revenue"
        }
    }

    static let groups: [(String, [Screen])] = [
        ("", [.overview, .live]),
        ("Traffic", [.pages, .sources, .campaigns, .search]),
        ("Audience", [.countries, .devices]),
        ("Behaviour", [.events, .goals, .errors, .performance]),
        ("Customers", [.revenue]),
    ]
}

/// The signed-in app: the chosen site's reports in a sidebar, or the site list.
struct SitesRoot: View {
    @Environment(AppModel.self) private var model
    let client: Client

    var body: some View {
        if let slug = model.selectedSite, let site = model.sites.first(where: { $0.slug == slug }) {
            SiteView(client: client, site: site)
                .id(site.slug)
        } else {
            SitesList(client: client)
        }
    }
}

/// Choose a site: each with today's visitors.
struct SitesList: View {
    @Environment(AppModel.self) private var model
    let client: Client

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.sites) { site in
                        Button {
                            model.selectedSite = site.slug
                        } label: {
                            HStack(spacing: 12) {
                                Text(site.initial)
                                    .font(Theme.display(20, relativeTo: .title2))
                                    .foregroundStyle(Theme.brand)
                                    .frame(width: 40, height: 40)
                                    .background(Theme.brand.opacity(0.12), in: .rect(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(site.name).font(.headline)
                                    Text(site.host).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(Format.count(site.today.visitors)).font(Theme.display(19, relativeTo: .title3)).monospacedDigit()
                                    Text("today").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(site.name), \(site.today.visitors) visitors today")
                    }
                } footer: {
                    Text("Signed in to \(client.instance.host). You can switch sites any time.")
                }
                if let error = model.sitesError {
                    Problem(title: "Sites didn’t load", detail: error)
                }
            }
            .navigationTitle("Choose a site")
            .refreshable { await model.loadSites() }
            .overlay {
                if model.sites.isEmpty && model.sitesError == nil { ProgressView() }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Sign Out", role: .destructive) { model.signOut() }
                }
            }
        }
    }
}

/// One site: sidebar of reports, the period and filters shared by all of them.
struct SiteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let client: Client
    let site: Site
    @State private var screen: Screen? = .overview
    @State private var view = ViewState()

    var body: some View {
        NavigationSplitView {
            List(selection: $screen) {
                ForEach(Screen.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { item in
                            Label(item.title, systemImage: item.symbol).tag(item)
                        }
                    }
                }
            }
            .navigationTitle(site.name)
            .toolbar {
                ToolbarItem {
                    Menu {
                        ForEach(model.sites) { other in
                            Button(other.name) { model.selectedSite = other.slug }
                        }
                        Divider()
                        Button("Sign Out", role: .destructive) { model.signOut() }
                    } label: {
                        Label("Sites", systemImage: "rectangle.stack")
                    }
                }
            }
        } detail: {
            NavigationStack {
                detail
                    .toolbar { toolbar }
                    .safeAreaInset(edge: .bottom) { FilterBar(view: $view) }
            }
        }
        .onChange(of: model.pendingLink, initial: true) { _, link in
            guard let link else { return }
            view = ViewState(url: link)
            let page = link.pathComponents.filter { $0 != "/" }.dropFirst().first
            screen = Screen.allCases.first { $0.workspacePage == page && $0 != .live } ?? .overview
            model.pendingLink = nil
        }
    }

    @ViewBuilder private var detail: some View {
        switch screen ?? .overview {
        case .overview: OverviewView(client: client, site: site, view: $view)
        case .live: LiveView(client: client, site: site)
        case let report: ReportScreen(client: client, site: site, screen: report, view: $view)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Period", selection: $view.period) {
                ForEach(ViewState.Period.allCases) { Text($0.short).tag($0) }
            }
            .pickerStyle(.menu)
        }
        ToolbarItem {
            Button {
                openURL(view.workspaceURL(origin: client.instance.origin, site: site.slug, page: screen?.workspacePage))
            } label: {
                Label("Open in workspace", systemImage: "safari")
            }
            .help("Open this view in the web workspace")
        }
    }
}

/// The active filters, each removable, like the workspace's filter chips.
struct FilterBar: View {
    @Binding var view: ViewState

    var body: some View {
        if !view.filters.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(view.filters) { filter in
                        Button {
                            view.filters.removeAll { $0 == filter }
                        } label: {
                            HStack(spacing: 4) {
                                Text(Labels.dimension(filter.dimension)).foregroundStyle(.secondary)
                                Text(filter.negated ? "is not" : "is").foregroundStyle(.secondary)
                                Text(Labels.value(filter.value, dimension: filter.dimension)).fontWeight(.semibold)
                                Image(systemName: "xmark").font(.caption2)
                            }
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.brand.opacity(0.1), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove filter \(Labels.dimension(filter.dimension)) \(filter.value)")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }
}

/// Display names for dimensions and the values the server sends.
enum Labels {
    static func dimension(_ name: String) -> String {
        switch name {
        case "os": "OS"
        default: name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    static func value(_ value: String, dimension: String) -> String {
        switch dimension {
        case "country":
            Locale.current.localizedString(forRegionCode: value) ?? value
        case "device", "browser", "os":
            ["macos": "macOS", "ios": "iOS"][value] ?? (value.prefix(1).uppercased() + value.dropFirst())
        case "source":
            value == "direct" ? "Direct" : value
        default:
            value
        }
    }
}
