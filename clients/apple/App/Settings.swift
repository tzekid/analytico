import AnalyticoKit
import SwiftUI

/// A site's letter on a tinted tile; each site keeps its tint.
struct SiteBadge: View {
    let site: Site
    var size: CGFloat = 40

    var body: some View {
        let tones = [(Theme.blue, Theme.blueWash), (Theme.teal, Theme.tealWash), (Theme.brand, Theme.brandWash), (Theme.violet, Theme.violetWash)]
        let tone = tones[Int(site.slug.unicodeScalars.reduce(0) { $0 + $1.value }) % tones.count]
        Text(site.initial)
            .font(Theme.display(size * 0.5, relativeTo: .title2))
            .foregroundStyle(tone.0)
            .frame(width: size, height: size)
            .background(tone.1, in: .rect(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}

/// Each site with today's visitors; the open one is checked.
struct SiteRows: View {
    @Environment(AppModel.self) private var model
    var chevrons = false
    var choose: (Site) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.sites.enumerated()), id: \.element.slug) { index, site in
                if index > 0 { Divider().padding(.leading, 66) }
                Button { choose(site) } label: {
                    HStack(spacing: 14) {
                        SiteBadge(site: site)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.name).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                            Text(site.host).font(.subheadline).foregroundStyle(Theme.ink2)
                        }
                        .lineLimit(1)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(Format.count(site.today.visitors)).font(Theme.display(20, relativeTo: .title3)).foregroundStyle(Theme.ink).monospacedDigit()
                            Text("today").font(.caption).foregroundStyle(Theme.ink2)
                        }
                        if chevrons {
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                        } else {
                            Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(Theme.brand)
                                .opacity(site.slug == model.selectedSite ? 1 : 0)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(site.name), \(site.today.visitors) visitors today")
                .accessibilityAddTraits(site.slug == model.selectedSite ? .isSelected : [])
            }
        }
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }
}

/// "Your sites": switch from the title bar (sheet on iPhone, popover on Mac and iPad).
struct SiteSwitcherSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your sites").font(Theme.display(26, relativeTo: .title)).foregroundStyle(Theme.ink)
                SiteRows { site in
                    model.selectedSite = site.slug
                    dismiss()
                }
                if let client = model.client {
                    VStack(spacing: 6) {
                        Text("Signed in to \(client.instance.host)\(model.me.map { " as \($0.email)" } ?? "")").font(.caption).foregroundStyle(Theme.ink2)
                        Button("Sign in to a different Analytico") { model.signOut() }
                            .buttonStyle(.plain).font(.subheadline.weight(.medium)).foregroundStyle(Theme.brandDark)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
            .padding(.top, 8)
        }
        .background(Theme.canvas)
        .task {
            await model.loadSites()
            await model.loadMe()
        }
    }
}

/// After sign-in, or when the open site is gone: choose a site.
struct SitesList: View {
    @Environment(AppModel.self) private var model
    let client: Client

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Mark(size: 26)
                    Text("Analytico").font(Theme.display(20, relativeTo: .title3)).foregroundStyle(Theme.ink)
                }
                .padding(.bottom, 12)
                Text("Choose a site").font(Theme.display(30, relativeTo: .largeTitle)).foregroundStyle(Theme.ink)
                Text(model.sites.isEmpty ? "Loading the sites you can see…" : "\(client.instance.host) has \(model.sites.count == 1 ? "one site" : "\(model.sites.count) sites") you can see. You can switch any time from the title bar.")
                    .foregroundStyle(Theme.ink2)
                if let error = model.sitesError {
                    Problem(title: "Sites didn’t load", detail: error)
                } else if model.sites.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    SiteRows(chevrons: true) { model.selectedSite = $0.slug }
                }
                Spacer(minLength: 40)
                HStack(spacing: 8) {
                    Text("Signed in to \(client.instance.host)")
                    Text("·")
                    Button("Use a different address") { model.signOut() }.buttonStyle(.plain).foregroundStyle(Theme.brandDark)
                }
                .font(.caption)
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .refreshable { await model.loadSites() }
    }
}

/// The sign-in ended (revoked in the workspace, or expired): say so, and
/// offer the same instance again or another one.
struct SignedOutView: View {
    @Environment(AppModel.self) private var model
    let host: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Signed out").font(Theme.display(30, relativeTo: .largeTitle)).foregroundStyle(Theme.ink)
                    Text(host).font(.subheadline).foregroundStyle(Theme.ink2)
                }
                StageView(art: "waiting", title: "Your sign-in ended",
                          text: "This \(Device.kind) was signed out — it was removed under Settings → Sign-in, or its sign-in expired. Your notes and views are safe.",
                          primary: ("Sign in again", { model.reconnect(to: host) }),
                          secondary: ("Use a different address", { model.reconnect(to: nil) }))
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
    }
}

/// Settings on iPhone and iPad: the account, this device's notifications,
/// the workspace, signing out.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    AccountSection()
                    NotificationsSection()
                    WorkspaceLinks()
                    SignOutButton()
                }
                .padding(16)
            }
            .background(Theme.canvas)
            .toolbar {
                ToolbarItem(placement: .principal) { EmptyView() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("Settings").font(Theme.display(30, relativeTo: .largeTitle)).foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .background(Theme.canvas)
            }
        }
        .tint(Theme.brand)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.canvas)
    }
}

/// Small caps over a group, as in the workspace.
struct GroupLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(0.5).foregroundStyle(Theme.ink2).padding(.leading, 14)
    }
}

/// A white grouped list, the cards of Settings.
struct GroupBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }
}

struct AccountSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupLabel("Account")
            GroupBox {
                HStack(spacing: 14) {
                    Text(initials).font(.headline).foregroundStyle(Theme.brandDark)
                        .frame(width: 48, height: 48).background(Theme.brandWash, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.me?.email ?? "…").font(.headline).foregroundStyle(Theme.ink)
                        Text(model.me.map { $0.role.prefix(1).uppercased() + $0.role.dropFirst() } ?? " ").font(.subheadline).foregroundStyle(Theme.ink2)
                    }
                    .lineLimit(1)
                }
                .padding(14)
                Divider().padding(.leading, 14)
                HStack {
                    Text(model.client?.instance.host ?? "").foregroundStyle(Theme.ink)
                    Spacer()
                    Text("Analytico").foregroundStyle(Theme.muted)
                }
                .padding(14)
            }
        }
        .task { await model.loadMe() }
    }

    private var initials: String {
        let name = model.me?.email.split(separator: "@").first ?? ""
        let parts = name.split(whereSeparator: { ".-_".contains($0) })
        return (parts.count > 1 ? parts.prefix(2).compactMap(\.first).map(String.init).joined() : String(name.prefix(2))).uppercased()
    }
}

struct NotificationsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var testing = false
    @State private var tested: String?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            GroupLabel("Notifications on this \(Device.kind)")
            GroupBox {
                if model.pushStatus == .denied {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notifications are turned off for Analytico.").foregroundStyle(Theme.ink)
                        #if os(iOS)
                        Button("Open Settings") { openURL(URL(string: UIApplication.openNotificationSettingsURLString)!) }.foregroundStyle(Theme.brandDark)
                        #else
                        Button("Open System Settings") { openURL(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }.foregroundStyle(Theme.brandDark)
                        #endif
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    Divider().padding(.leading, 14)
                }
                ForEach(PushKind.allCases) { kind in
                    Toggle(isOn: Binding(get: { model.pushKinds.contains(kind) }, set: { on in
                        if on { model.pushKinds.insert(kind) } else { model.pushKinds.remove(kind) }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title).foregroundStyle(Theme.ink)
                            Text(kind.detail).font(.caption).foregroundStyle(Theme.ink2)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    Divider().padding(.leading, 14)
                }
                Button {
                    Task { await sendTest() }
                } label: {
                    HStack(spacing: 10) {
                        Icon("send", size: 18)
                        Text(testing ? "Sending…" : "Send a test notification")
                        Spacer()
                    }
                    .foregroundStyle(Theme.brandDark)
                    .padding(14)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(testing || model.pushStatus == .denied)
            }
            Text(tested ?? "Notifications are encrypted for this \(Device.kind); only it can read them. Alerts themselves are set up in the workspace.")
                .font(.caption).foregroundStyle(Theme.ink2).padding(.horizontal, 14)
            if let problem = model.pushProblem { Text(problem).font(.caption).foregroundStyle(Theme.bad).padding(.horizontal, 14) }
        }
        .task { await model.enablePush() }
    }

    private func sendTest() async {
        guard let client = model.client else { return }
        testing = true
        defer { testing = false }
        do {
            try await client.sendTestNotification()
            tested = "Sent. It arrives in a few seconds; if it doesn’t, check that notifications are allowed for Analytico."
        } catch ClientError.server(_, "device_not_registered") {
            tested = "This \(Device.kind) isn’t registered for notifications yet. Allow notifications, then try again."
        } catch {
            tested = "The test wasn’t sent. Check the connection, or update your Analytico."
        }
    }
}

extension PushKind {
    var detail: String {
        switch self {
        case .alert: "When a metric crosses a line you set"
        case .goal: "One notification per site, per minute"
        case .note: "A note when traffic looks different"
        }
    }
}

struct WorkspaceLinks: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let origin = model.client?.instance.origin {
            GroupBox {
                link("Open the workspace", origin.appending(path: model.selectedSite ?? ""))
                Divider().padding(.leading, 14)
                link("Signed-in devices", origin.appending(path: "settings/signin"))
            }
        }
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack {
                Text(title).foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            .padding(14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct SignOutButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.signOut() } label: {
            Text("Sign out of this \(Device.kind)").foregroundStyle(Theme.bad).frame(maxWidth: .infinity).padding(14)
                .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

#if os(macOS)
/// The Mac's Settings window: Account · Notifications · Sites.
struct SettingsWindow: View {
    @AppStorage("menuBar") private var menuBar = true

    var body: some View {
        TabView {
            Tab { pane { AccountSection(); WorkspaceLinks(); SignOutButton() } } label: { Label("Account", image: "Icons/team") }
            Tab {
                pane {
                    NotificationsSection()
                    GroupBox {
                        Toggle(isOn: $menuBar) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show Analytico in the menu bar").foregroundStyle(Theme.ink)
                                Text("People online now on the site you have open").font(.caption).foregroundStyle(Theme.ink2)
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(Theme.primary)
                        .padding(14)
                    }
                }
            } label: { Label("Notifications", image: "Icons/bell-plus") }
            Tab { pane { SitesPane() } } label: { Label("Sites", image: "Icons/sites") }
        }
        .tint(Theme.brand)
        .frame(width: 560)
    }

    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content() }.padding(22)
        }
        .frame(minHeight: 420)
        .background(Theme.canvas)
    }
}

private struct SitesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupLabel("Open in the main window")
            SiteRows { model.selectedSite = $0.slug }
            Text("Each site’s numbers come from \(model.client?.instance.host ?? "your Analytico"). Add sites in the workspace.").font(.caption).foregroundStyle(Theme.ink2).padding(.horizontal, 14)
        }
        .task { await model.loadSites() }
    }
}
#endif

@MainActor
extension Device {
    /// "iPhone", "iPad", "Mac", for sentences about this device.
    static var kind: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}
