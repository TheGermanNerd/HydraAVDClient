import SwiftUI
import HydraRdpCore

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case personalization
    case fullScreen
    case notifications
    case keyboard
    case resolutions
    case credentials
    case gateways
    case groups
    case hydra

    var id: String { rawValue }

    static var windowsApp: [SettingsSection] {
        allCases.filter { $0 != .hydra }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .personalization: return "Personalization"
        case .fullScreen: return "Full Screen Mode"
        case .notifications: return "Notifications"
        case .keyboard: return "Keyboard"
        case .resolutions: return "Resolutions"
        case .credentials: return "Credentials"
        case .gateways: return "Gateways"
        case .groups: return "Groups"
        case .hydra: return "Hydra"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .personalization: return "paintbrush"
        case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        case .notifications: return "bell"
        case .keyboard: return "keyboard"
        case .resolutions: return "display"
        case .credentials: return "key"
        case .gateways: return "network"
        case .groups: return "folder"
        case .hydra: return "drop"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(white: 0.78)
        case .personalization: return Color(red: 0.35, green: 0.78, blue: 0.95)
        case .fullScreen: return Color(red: 0.30, green: 0.86, blue: 0.40)
        case .notifications: return Color(red: 0.95, green: 0.35, blue: 0.38)
        case .keyboard: return Color(white: 0.68)
        case .resolutions: return Color(red: 0.35, green: 0.62, blue: 0.98)
        case .credentials: return Color(red: 0.98, green: 0.75, blue: 0.28)
        case .gateways: return Color(red: 0.72, green: 0.45, blue: 0.95)
        case .groups: return Color(red: 0.35, green: 0.62, blue: 0.98)
        case .hydra: return Color(red: 0.40, green: 0.75, blue: 0.95)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    var onClose: () -> Void
    @StateObject private var navigation = SettingsNavigation()

    init(model: AppModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _preferences = ObservedObject(wrappedValue: model.preferences)
    }

    private var section: SettingsSection {
        navigation.section
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
            VStack(spacing: 0) {
                header
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Chrome.canvas)
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.windowsApp) { item in
                sectionButton(item)
            }
            Divider()
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            sectionButton(.hydra)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Chrome.sidebar)
    }

    private func sectionButton(_ item: SettingsSection) -> some View {
        let selected = section == item
        return Button {
            select(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .foregroundStyle(selected ? Color.white : item.tint)
                    .frame(width: 18)
                Text(item.title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Chrome.menuBlue : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings-section-\(item.rawValue)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            historyControls
            Spacer()
            Button("Save", action: onClose)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("settings-save")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var historyControls: some View {
        HStack(spacing: 0) {
            historyButton(
                "chevron.left",
                label: "Back",
                identifier: "settings-back",
                enabled: navigation.canGoBack,
                action: navigation.goBack
            )
            historyButton(
                "chevron.right",
                label: "Forward",
                identifier: "settings-forward",
                enabled: navigation.canGoForward,
                action: navigation.goForward
            )
        }
        .padding(2)
        .background(Chrome.raised)
        .clipShape(Capsule())
    }

    private func historyButton(
        _ symbol: String,
        label: String,
        identifier: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 22)
                .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.28))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .general:
            GeneralSettingsPage(preferences: preferences)
        case .personalization:
            PersonalizationSettingsPage()
        case .fullScreen:
            FullScreenSettingsPage()
        case .notifications:
            NotificationsSettingsPage()
        case .keyboard:
            KeyboardSettingsPage()
        case .resolutions:
            ResolutionsSettingsPage()
        case .credentials:
            CredentialsSettingsPage()
        case .gateways:
            GatewaysSettingsPage()
        case .groups:
            GroupsSettingsPage()
        case .hydra:
            HydraSettingsPage(model: model, preferences: preferences)
        }
    }

    private func select(_ next: SettingsSection) {
        navigation.select(next)
    }
}

private final class SettingsNavigation: ObservableObject {
    @Published private var history: [SettingsSection] = [.general]
    @Published private var historyIndex = 0

    var section: SettingsSection { history[historyIndex] }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    func select(_ next: SettingsSection) {
        guard next != section else { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(next)
        historyIndex = history.count - 1
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
    }
}

private struct GeneralSettingsPage: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsGroup("Connection") {
                    SettingToggleRow(
                        title: "Use HTTP proxy",
                        caption: "Use the HTTP proxy specified in network settings when downloading workspaces and connecting to RD gateway servers.",
                        isOn: $preferences.useHTTPProxy,
                        identifier: "use-http-proxy"
                    )
                    settingDivider
                    SettingToggleRow(
                        title: "Use UDP where possible",
                        caption: "Use UDP Shortpath when available to provide faster, lower-latency connections.",
                        isOn: $preferences.useUDP,
                        identifier: "use-udp"
                    )
                    settingDivider
                    SettingToggleRow(
                        title: "Enable optimizations for Microsoft Teams",
                        caption: "Optimize audio and video streams when connecting to servers that support Teams redirection.",
                        isOn: $preferences.teamsOptimizations,
                        identifier: "teams-optimizations"
                    )
                    settingDivider
                    SettingToggleRow(
                        title: "Use WebAuthn redirection",
                        caption: "Complete in-session WebAuthn requests using passwordless credentials available on your local device for Azure Virtual Desktop and Windows 365 connections",
                        isOn: $preferences.webAuthnRedirection,
                        identifier: "webauthn-redirection"
                    )
                }
                settingsCard {
                    SettingToggleRow(
                        title: "Share data with Microsoft",
                        caption: "Send optional diagnostics data to Microsoft to help improve Windows App.",
                        isOn: $preferences.shareDiagnostics,
                        identifier: "share-diagnostics"
                    )
                }
                Text("Graphics")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            settingsCard(content: content)
        }
    }

    private var settingDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 14)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Chrome.raised)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingToggleRow: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool
    var identifier: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityIdentifier(identifier)
    }
}

private struct SettingsUnavailablePage: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text("These settings are not available yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PersonalizationSettingsPage: View {
    var body: some View { SettingsUnavailablePage(title: "Personalization") }
}

private struct FullScreenSettingsPage: View {
    var body: some View { SettingsUnavailablePage(title: "Full Screen Mode") }
}

private struct NotificationsSettingsPage: View {
    var body: some View { SettingsUnavailablePage(title: "Notifications") }
}

private struct KeyboardSettingsPage: View {
    var body: some View { SettingsUnavailablePage(title: "Keyboard") }
}

private struct ResolutionsSettingsPage: View {
    var body: some View { SettingsUnavailablePage(title: "Resolutions") }
}

private struct CredentialsSettingsPage: View {
    var body: some View { SettingsUnavailablePage(title: "Credentials") }
}

private struct GatewaysSettingsPage: View {
    var body: some View { SettingsUnavailablePage(title: "Gateways") }
}

private struct GroupsSettingsPage: View {
    var body: some View { SettingsUnavailablePage(title: "Groups") }
}

private struct HydraSettingsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Hydra") {
                SecureField("Client key", text: $model.clientKey)
                    .accessibilityIdentifier("client-key")
                Text("Stored in the Keychain service \(KeychainStore.service). It is not written into the snapshot or the log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Collection") {
                Toggle("Continuous ping", isOn: $preferences.pingEnabled)
                TextField("Ping target", text: $preferences.pingTarget)
                Picker("Network interface", selection: interfaceSelection) {
                    Text("Automatic").tag(String?.none)
                    ForEach(interfaceChoices) { choice in
                        Text(interfaceLabel(choice)).tag(Optional(choice.name))
                    }
                }
                .pickerStyle(.menu)
                Toggle("Include sensitive data", isOn: $preferences.showSensitiveData)
                Text("Sensitive data stays off unless you enable it. Automatic uses the system default route. A chosen interface is used for the gateway, the public IP, and pings. The ping target defaults to 8.8.8.8.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Extra channels") {
                HStack {
                    Text("HYDAGX01")
                    Spacer()
                    Text("Built in, always on").foregroundStyle(.secondary)
                }
                ForEach($model.channels) { $channel in
                    HStack {
                        TextField("Channel name", text: $channel.name)
                        Picker("Handler", selection: $channel.kind) {
                            ForEach(ExtraChannelKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .labelsHidden()
                        if channel.kind == .library {
                            TextField("Library path", text: $channel.libraryPath)
                        }
                        Toggle("On", isOn: $channel.enabled)
                            .labelsHidden()
                    }
                }
                .onDelete { model.channels.remove(atOffsets: $0); model.saveChannels() }
                let libraries = HydraPaths.librariesInChannelsFolder()
                HStack {
                    Button("Add echo channel") {
                        model.channels.append(ExtraChannel(name: "ECHO01", kind: .echo))
                        model.saveChannels()
                    }
                    Button("Add library channel") {
                        let path = libraries.first?.path ?? ""
                        model.channels.append(ExtraChannel(name: "CUST01", kind: .library, libraryPath: path))
                        model.saveChannels()
                    }
                }
                if libraries.isEmpty {
                    Text("Drop DVCPluginEntry libraries in \(HydraPaths.channelsDirectory.path).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Libraries in the Channels folder: \(libraries.map(\.lastPathComponent).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !model.status.isEmpty {
                Text(model.status).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .onChange(of: model.channels) { _ in
            model.saveChannels()
        }
    }

    private var interfaces: [ListedNetworkInterface] {
        NetworkInterfaceCatalog.current()
    }

    private var interfaceSelection: Binding<String?> {
        Binding(
            get: {
                let name = preferences.networkInterface.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            },
            set: { preferences.networkInterface = $0 ?? "" }
        )
    }

    private var interfaceChoices: [ListedNetworkInterface] {
        var choices = interfaces
        let selected = preferences.networkInterface.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty, !choices.contains(where: { $0.name == selected }) {
            choices.append(ListedNetworkInterface(name: selected, ipv4Address: nil))
        }
        return choices
    }

    private func interfaceLabel(_ choice: ListedNetworkInterface) -> String {
        if interfaces.contains(where: { $0.name == choice.name }) {
            return choice.menuTitle
        }
        return "\(choice.name) (not connected)"
    }
}
