import AnalyticoKit
import AppIntents
import Foundation

/// A website on the signed-in instance, for Siri, Shortcuts and widgets.
struct SiteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Website"
    static let defaultQuery = SiteQuery()

    let id: String
    let name: String
    let host: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(host)")
    }

    init(_ site: Site) {
        id = site.slug
        name = site.name
        host = site.host
    }
}

struct SiteQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SiteEntity] {
        try await sites().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SiteEntity] {
        try await sites()
    }

    /// The site open in the app, so a widget shows something without setup.
    func defaultResult() async -> SiteEntity? {
        let all = (try? await sites()) ?? []
        return all.first { $0.id == Shared.site } ?? all.first
    }

    private func sites() async throws -> [SiteEntity] {
        guard let client = Shared.client() else { return [] }
        return try await client.sites().map(SiteEntity.init)
    }
}

/// "How many visitors today on shop?"
struct VisitorsTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Visitors today"
    static let description = IntentDescription("Visitors and page views on a website so far today.")

    @Parameter(title: "Website") var site: SiteEntity

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let client = Shared.client() else {
            throw IntentError.signedOut
        }
        guard let today = try await client.sites().first(where: { $0.slug == site.id })?.today else {
            throw IntentError.unknownSite
        }
        let visitors = today.visitors == 1 ? "1 visitor" : "\(Format.count(today.visitors)) visitors"
        return .result(value: today.visitors, dialog: "\(visitors) on \(site.name) today, \(Format.count(today.pageViews)) page views.")
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case unknownSite

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Open Analytico and sign in first."
        case .unknownSite: "That website isn’t on your Analytico any more."
        }
    }
}

/// The widget's settings: which website it shows.
struct SiteWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Website"
    static let description = IntentDescription("Today’s visitors and the last week for one website.")

    @Parameter(title: "Website") var site: SiteEntity?
}
