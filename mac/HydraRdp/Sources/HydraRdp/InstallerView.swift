import AppKit
import HydraRdpCore
import SwiftUI

@MainActor
final class InstallerForm: ObservableObject {
    @Published var step: Int
    @Published var key = ""
    @Published var confirmation = ""
    @Published var feedURL: String
    @Published var message = ""
    @Published var installing = false
    let license: (version: String, body: String, complete: Bool)

    init(model: AppModel) {
        license = LicenseTexts.load()
        let needsLicense = InstallerRules.needsLicenseAcceptance(
            acceptedVersion: model.preferences.licenseAcceptedNoticesVersion,
            currentVersion: license.version
        )
        step = needsLicense ? 0 : 1
        feedURL = model.preferences.workspaceFeedURL
    }
}

struct InstallerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var form: InstallerForm

    var body: some View {
        ZStack {
            Chrome.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text("Install Hydra AVD Client")
                    .font(.title2.weight(.semibold))
                Text(stepTitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if !form.message.isEmpty {
                    Text(form.message)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack {
                    if form.step > 0 {
                        Button("Back") {
                            form.step -= 1
                            form.message = ""
                        }
                        .disabled(form.installing)
                    }
                    Spacer()
                    if form.step == 0 {
                        Button("Disagree") { NSApp.terminate(nil) }
                        Button("Agree") { agree() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!form.license.complete)
                    } else if form.step == 4 {
                        Button(installButtonTitle) { install() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(form.installing || !canInstall)
                    } else {
                        Button("Continue") { advance() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 720, maxHeight: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stepTitle: String {
        switch form.step {
        case 0: return "License agreement"
        case 1: return "Hydra client key"
        case 2: return "Workspace feed"
        case 3: return "Permissions"
        default: return "Install"
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch form.step {
        case 0:
            Text("Hydra AVD Client includes FreeRDP, OpenSSL, and json-c. Agree to continue installing.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(form.license.body)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case 1:
            Text("Enter the Hydra client key from your administrator. It is the same secret as the Windows plugin value ChannelSecret. The key is saved in the Keychain on this Mac and is not written into logs.")
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Client key", text: $form.key)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm client key", text: $form.confirmation)
                .textFieldStyle(.roundedBorder)
        case 2:
            Text("An administrator can give you a workspace feed URL. Leave this blank if you add computers yourself or sign in later.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://workspace.example.com", text: $form.feedURL)
                .textFieldStyle(.roundedBorder)
        case 3:
            Text("macOS asks for these permissions when the feature is used. This step does not request them.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Local Network — used when Hydra AVD Client connects to a computer on your local network.")
            Text("Location — used when a remote session asks for the client location.")
        default:
            if InstallerRules.isRunningInstalledApp(bundlePath: Bundle.main.bundlePath) {
                Text("Hydra AVD Client is already in the Applications folder. Continue to open the library.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Hydra AVD Client will be copied to the Applications folder. The client key stays in the Keychain on this Mac.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canInstall: Bool {
        !model.clientKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || InstallerRules.clientKeyConfirmed(form.key, confirmation: form.confirmation)
    }

    private var installButtonTitle: String {
        InstallerRules.isRunningInstalledApp(bundlePath: Bundle.main.bundlePath) ? "Continue" : "Install"
    }

    private func agree() {
        guard form.license.complete else {
            form.message = "The license texts are missing from this copy of the app."
            return
        }
        model.preferences.licenseAcceptedNoticesVersion = form.license.version
        form.message = ""
        form.step = 1
    }

    private func advance() {
        form.message = ""
        if form.step == 1 {
            guard let normalized = InstallerRules.normalizedClientKey(form.key, confirmation: form.confirmation) else {
                form.message = "Enter the client key twice, using the same value."
                return
            }
            model.clientKey = normalized
            guard model.saveClientKey() else {
                form.message = model.status
                return
            }
            form.step = 2
            return
        }
        if form.step == 2 {
            let trimmed = form.feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard InstallerRules.workspaceFeedURLIsValid(trimmed) else {
                form.message = "Enter an http or https workspace URL."
                return
            }
            model.preferences.workspaceFeedURL = trimmed
            form.step = 3
            return
        }
        form.step = 4
    }

    private func install() {
        form.message = ""
        if model.clientKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let normalized = InstallerRules.normalizedClientKey(form.key, confirmation: form.confirmation) else {
                form.message = "Enter the client key twice, using the same value."
                form.step = 1
                return
            }
            model.clientKey = normalized
            guard model.saveClientKey() else {
                form.message = model.status
                return
            }
        }
        if InstallerRules.isRunningInstalledApp(bundlePath: Bundle.main.bundlePath) {
            model.showingInstaller = false
            return
        }
        form.installing = true
        let destination = URL(fileURLWithPath: InstallerRules.installedAppPath)
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: Bundle.main.bundleURL, to: destination)
        } catch {
            form.installing = false
            form.message = "Could not copy the app into Applications. Drag Hydra AVD Client onto the Applications shortcut in the disk image. \(error.localizedDescription)"
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.form.installing = false
                    self.form.message = error.localizedDescription
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}
