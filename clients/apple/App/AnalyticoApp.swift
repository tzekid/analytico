import AnalyticoKit
import SwiftUI

@main
struct AnalyticoApp: App {
    @State private var model = AppModel()

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
    }
}

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
