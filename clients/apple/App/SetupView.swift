import AnalyticoKit
import AuthenticationServices
import SwiftUI

/// The first screen: which Analytico to connect to, checked as you type,
/// then sign-in on the instance's own page in a browser sheet.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var address = ""
    @State private var check: InstanceCheck?
    @State private var checking = false
    @State private var signingIn = false
    @State private var signInError: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Mark()
                    Text("Analytico").font(Theme.display(19, relativeTo: .title3))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(signingIn ? "Finish signing in" : "Connect to your Analytico")
                        .font(Theme.display(30))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(signingIn ? "Sign in on \(check?.instance?.host ?? "your instance") with \(check?.instance?.signInSummary ?? "your account"). You come back here as soon as you’re done." : "Enter the address you open Analytico at in your browser. The app checks it before you sign in.")
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !signingIn { field }
                result
                actions
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.canvas)
        .task(id: address) { await checkAddress() }
        .onAppear {
            if let host = model.prefill {
                address = host
                model.prefill = nil
            }
            focused = true
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Analytico address").font(Theme.subheadline.weight(.medium))
            HStack(spacing: 2) {
                if !address.contains("://") { Text("https://").foregroundStyle(Theme.ink2) }
                TextField("analytics.example.com", text: $address)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($focused)
                    .onSubmit { Task { await signIn() } }
                    .accessibilityLabel("Your Analytico address")
                status
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(Theme.surface, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(borderColor, lineWidth: borderColor == .clear ? 0 : 1.5))
        }
    }

    @ViewBuilder private var status: some View {
        if checking {
            ProgressView().controlSize(.small)
        } else if case .ready = check {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good).accessibilityLabel("Checked")
        } else if check != nil && check != .invalidAddress {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.bad).accessibilityLabel("Problem")
        }
    }

    private var borderColor: Color {
        switch check {
        case .ready: Theme.good
        case .none, .invalidAddress: .secondary.opacity(0.3)
        default: Theme.bad
        }
    }

    @ViewBuilder private var result: some View {
        switch check {
        case .ready(let instance):
            InstanceCard(instance: instance, signingIn: signingIn)
        case .unreachable(let host):
            Problem(title: "Can’t reach \(host)", detail: "Check the address and your connection. The app needs the same address you use in the browser.")
        case .untrusted(let host):
            Problem(title: "The certificate for \(host) isn’t valid", detail: "The app only connects over a secure connection. Ask whoever runs the instance to renew its certificate.")
        case .notAnalytico(let host):
            Problem(title: "\(host) isn’t an Analytico instance", detail: "It answered, but not as Analytico. The workspace usually has its own subdomain, such as analytics.\(host). Copy the address from the browser tab where you use Analytico.")
        case .needsUpdate(let instance):
            Problem(title: "\(instance.host) needs an update", detail: "It runs Analytico \(instance.version), which this app can’t read yet. Ask its owner to update Analytico.")
        case .newerAppNeeded(let instance):
            Problem(title: "This app needs an update", detail: "\(instance.host) runs a newer Analytico. Update the app from the App Store.")
        case .notSetUp(let instance):
            Problem(title: "\(instance.host) isn’t set up yet", detail: "Open it in a browser and create the first account, then come back.")
        case .invalidAddress, .none:
            EmptyView()
        }
        if let signInError {
            Problem(title: "Sign-in didn’t finish", detail: signInError)
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 16) {
            if signingIn {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the sign-in page…").foregroundStyle(Theme.ink2)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Theme.surface, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.3)))
            } else {
                Button("Continue in browser") {
                    Task { await signIn() }
                }
                .buttonStyle(PrimaryButtonStyle(wide: true))
                .disabled(check?.instance == nil)
                Text("You sign in on your instance’s own page, with your passkey or Google. The app only receives a token you can revoke in Settings → Sign-in.")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func checkAddress() async {
        signInError = nil
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else {
            check = nil
            return
        }
        // Wait for a pause in typing before asking the network.
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        checking = true
        let outcome = await InstanceChecker.check(address)
        guard !Task.isCancelled else { return }
        checking = false
        check = outcome
    }

    private func signIn() async {
        guard let instance = check?.instance, !signingIn else { return }
        let flow = SignIn(instance: instance, deviceName: Device.name)
        signingIn = true
        signInError = nil
        defer { signingIn = false }
        do {
            let callback = try await webAuthenticationSession.authenticate(using: flow.url, callback: .customScheme(AppClient.scheme), additionalHeaderFields: [:])
            let tokens = try await flow.finish(callback: callback)
            model.signedIn(instance, tokens: tokens)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch AuthError.cancelled {
            return
        } catch {
            signInError = "The sign-in page didn’t hand back a valid sign-in. Try again."
        }
    }
}

/// The checked instance: who it is, and what was verified.
struct InstanceCard: View {
    let instance: Instance
    var signingIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(String(instance.host.prefix(1)).uppercased())
                    .font(Theme.display(20, relativeTo: .title2))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 40, height: 40)
                    .background(Theme.brand.opacity(0.12), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.host).font(.headline)
                    Text("Analytico \(instance.version)").font(Theme.subheadline).foregroundStyle(Theme.ink2)
                }
                Spacer()
                Text(signingIn ? "Signing in" : "Ready")
                    .font(Theme.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .foregroundStyle(signingIn ? Theme.warning : Theme.good)
                    .background((signingIn ? Theme.warning : Theme.good).opacity(0.1), in: .capsule)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(instance.origin.scheme == "https" ? "Reachable over HTTPS, certificate valid" : "Reachable on your network (no HTTPS)", systemImage: "checkmark")
                Label("Works with this app", systemImage: "checkmark")
                Label("Sign in with \(instance.signInSummary)", systemImage: "checkmark")
            }
            .font(Theme.subheadline)
            .foregroundStyle(Theme.ink2)
            .labelStyle(CheckLabelStyle())
        }
        .padding(18)
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.2)))
        .accessibilityElement(children: .combine)
    }
}

private struct CheckLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Theme.good).fontWeight(.bold)
            configuration.title
        }
    }
}

/// What went wrong, and what to do about it.
struct Problem: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(Theme.bad)
            Text(detail).font(Theme.subheadline).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bad.opacity(0.07), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
enum Device {
    /// What Settings → Sign-in calls this device: "MacBook Pro", "iPhone".
    static var name: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.model
        #endif
    }
}
