import AnalyticoKit
import AppIntents
import SwiftUI

@main
struct AnalyticoApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    #else
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    #endif
    private var model: AppModel { delegate.model }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.open($0) }
                .tint(Theme.brand)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sign Out") { model.signOut() }
                    .disabled(model.client == nil)
            }
        }
        #endif
        #if os(macOS)
        Settings {
            NotificationSettings().environment(model)
        }
        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            Label(model.online.map { "\($0)" } ?? "", systemImage: "chart.bar.fill")
                .labelStyle(.titleAndIcon)
        }
        #endif
    }
}

/// "How many visitors today on shop?" from Siri, Spotlight and Shortcuts.
struct AnalyticoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: VisitorsTodayIntent(), phrases: [
            "Visitors today in \(.applicationName)",
            "How many visitors on \(\.$site) in \(.applicationName)",
        ], shortTitle: "Visitors today", systemImageName: "chart.bar")
    }
}

#if os(macOS)
/// The menu bar: people online now on the open site, and its siblings.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.client == nil {
            Text("Not signed in")
        } else {
            if let slug = model.selectedSite, let site = model.sites.first(where: { $0.slug == slug }) {
                Text("\(model.online ?? 0) online now on \(site.name)")
                Text("\(Format.count(site.today.visitors)) visitors today")
                Divider()
            }
            ForEach(model.sites) { site in
                Button {
                    model.selectedSite = site.slug
                } label: {
                    Text(site.name + (site.slug == model.selectedSite ? " ✓" : ""))
                }
            }
        }
        Divider()
        Button("Open Analytico") { NSApp.activate() }
            .keyboardShortcut("o")
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
#endif

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .setup:
            SetupView()
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 620)
                #endif
        case .signedIn(let client):
            SitesRoot(client: client)
                .task { await model.loadSites() }
        }
    }
}
