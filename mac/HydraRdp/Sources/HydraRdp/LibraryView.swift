import AppKit
import SwiftUI
import HydraRdpCore

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @StateObject private var ui = LibraryUI()

    init(model: AppModel) {
        self.model = model
        _preferences = ObservedObject(wrappedValue: model.preferences)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
            browser
        }
        .background(Chrome.canvas)
        .background(WindowChrome())
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 640)
        .overlay { settingsOverlay }
        .overlay { publishedPCOverlay }
        .sheet(isPresented: $ui.showingWorkspaceURL) {
            WorkspaceURLSheet { url in
                Task { await model.addWorkspace(urlString: url) }
            }
        }
        .sheet(isPresented: $model.showingDesktopForm) {
            DesktopForm(model: model, desktop: model.editingDesktop)
        }
        .sheet(item: $model.desktopSignIn) { request in
            DesktopSignInSheet(model: model, request: request)
        }
        .confirmationDialog(
            "Remove this PC?",
            isPresented: removalPresented,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let desktop = ui.desktopPendingRemoval {
                    model.deleteDesktop(desktop)
                }
                ui.desktopPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { ui.desktopPendingRemoval = nil }
        } message: {
            Text(ui.desktopPendingRemoval.map { "\($0.listTitle) is removed from this Mac. The PC itself is left as it is." } ?? "")
        }
    }

    @ViewBuilder
    private var settingsOverlay: some View {
        if ui.showingSettings {
            ZStack {
                Color.black.opacity(0.5)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeSettings)
                SettingsView(model: model, onClose: closeSettings)
                    .frame(width: 820, height: 600)
                    .background(Chrome.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .background {
                Button(action: closeSettings) { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close settings")
            }
        }
    }

    private func closeSettings() {
        model.saveClientKey()
        model.saveChannels()
        ui.showingSettings = false
    }

    @ViewBuilder
    private var publishedPCOverlay: some View {
        if let resource = ui.resourcePendingConfigure {
            ZStack {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { ui.resourcePendingConfigure = nil }
                PublishedPCSheet(model: model, resource: resource) {
                    ui.resourcePendingConfigure = nil
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }

    private var removalPresented: Binding<Bool> {
        Binding(
            get: { ui.desktopPendingRemoval != nil },
            set: { if !$0 { ui.desktopPendingRemoval = nil } }
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 40)
            pageButton(.favorites, "Favorites", "star")
            pageButton(.devices, "Devices", "display")
            pageButton(.apps, "Apps", "square.grid.2x2")
            Spacer(minLength: 0)
            accountButton
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Chrome.sidebar)
    }

    private func pageButton(_ item: LibraryPage, _ title: String, _ symbol: String) -> some View {
        Button {
            ui.page = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: ui.page == item ? .semibold : .regular))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ui.page == item ? Chrome.selection : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(ui.page == item ? .isSelected : [])
    }

    private var accountButton: some View {
        Button {
            ui.showingAccount = true
        } label: {
            HStack(spacing: 10) {
                accountAvatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(accountTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(accountSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $ui.showingAccount, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                accountAction("Settings") {
                    ui.showingAccount = false
                    ui.showingSettings = true
                }
                if model.signedIn {
                    accountAction("Sign out") {
                        ui.showingAccount = false
                        model.signOut()
                    }
                } else {
                    accountAction("Add Work or School Account") {
                        ui.showingAccount = false
                        Task { await model.signIn() }
                    }
                }
            }
            .padding(6)
            .frame(width: 260)
        }
    }

    private func accountAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var accountAvatar: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.16))
            if accountInitials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Text(accountInitials)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 32, height: 32)
    }

    private var accountTitle: String {
        if !model.accountName.isEmpty { return model.accountName }
        if model.signedIn { return "Signed in" }
        return "Not signed in"
    }

    private var accountSubtitle: String {
        if !model.workspaceName.isEmpty { return model.workspaceName }
        if !model.accountUsername.isEmpty { return model.accountUsername }
        return model.signedIn ? "Work or school account" : "Add an account"
    }

    private var accountInitials: String {
        let source = model.accountName.isEmpty ? model.accountUsername : model.accountName
        let parts = source.split { $0 == " " || $0 == "@" || $0 == "." || $0 == "_" }
        let letters = parts.prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }

    private var browser: some View {
        VStack(spacing: 0) {
            toolbar
            if visibleSections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(visibleSections) { section in
                            sectionView(section)
                        }
                        if !model.status.isEmpty {
                            Text(model.status)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Chrome.canvas)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button {
                ui.showingAdd = true
            } label: {
                chromeIcon("plus")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add")
            .accessibilityIdentifier("library-add")
            .popover(isPresented: $ui.showingAdd, arrowEdge: .top) {
                AddMenu(
                    onAccount: {
                        ui.showingAdd = false
                        Task { await model.signIn() }
                    },
                    onWorkspace: {
                        ui.showingAdd = false
                        ui.showingWorkspaceURL = true
                    },
                    onPC: {
                        ui.showingAdd = false
                        beginAddPC()
                    }
                )
            }
            Button {
                Task { await model.refreshFeed() }
            } label: {
                chromeIcon("arrow.clockwise")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh")
            Button {
                ui.showingNotifications = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    chromeIcon("bell")
                    if !model.status.isEmpty {
                        Circle()
                            .fill(Color(red: 0.25, green: 0.55, blue: 1))
                            .frame(width: 7, height: 7)
                            .offset(x: 2, y: -1)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Notifications")
            .popover(isPresented: $ui.showingNotifications, arrowEdge: .top) {
                Text(model.status.isEmpty ? "No notifications" : model.status)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 280, alignment: .leading)
                    .padding(14)
            }
            layoutToggle
            Menu {
                Picker("Sort", selection: $ui.sortAscending) {
                    Text("Name A–Z").tag(true)
                    Text("Name Z–A").tag(false)
                }
            } label: {
                chromeIcon("arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Sort")
            Menu {
                Picker("Filter", selection: $ui.filter) {
                    ForEach(DeviceFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
            } label: {
                chromeIcon("line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Filter")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Search", text: $ui.query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .frame(width: 180, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Chrome.raised))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var layoutToggle: some View {
        HStack(spacing: 2) {
            layoutButton(.grid, "square.grid.2x2", "Grid")
            layoutButton(.list, "list.bullet", "List")
        }
        .padding(3)
        .background(Capsule().fill(Chrome.raised))
    }

    private func layoutButton(_ item: LibraryLayout, _ symbol: String, _ label: String) -> some View {
        Button {
            ui.layout = item
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(ui.layout == item ? 1 : 0.7))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(ui.layout == item ? Color.white.opacity(0.16) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(ui.layout == item ? .isSelected : [])
    }

    private func chromeIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: 28, height: 28)
            .background(Circle().fill(Chrome.raised))
    }

    private func sectionView(_ section: DeviceSection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                setOpen(!isOpen(section.kind), section.kind)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen(section.kind) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                    Text(section.title)
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.92))
            }
            .buttonStyle(.plain)
            if isOpen(section.kind) {
                if ui.layout == .grid {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 236, maximum: 280), spacing: 16, alignment: .leading)],
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(section.items) { item in
                            deviceButton(item)
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(section.items) { item in
                            deviceButton(item)
                        }
                    }
                }
            }
        }
    }

    private func deviceButton(_ item: DeviceItem) -> some View {
        DeviceTile(
            item: item,
            layout: ui.layout,
            selected: ui.selectedID == item.id,
            hovered: ui.hoveredID == item.id,
            menuOpen: ui.actionMenuID == item.id,
            onSelect: { ui.selectedID = item.id },
            onOpen: { open(item) },
            onToggleMenu: { toggleMenu(item) },
            onDismissMenu: { dismissMenu(item) },
            onToggleFavorite: { toggleFavorite(item) },
            onConfigure: { configure(item) }
        )
        .zIndex(ui.actionMenuID == item.id ? 2 : 0)
        .onHover { hovering in
            ui.hoveredID = hovering ? item.id : (ui.hoveredID == item.id ? nil : ui.hoveredID)
        }
        .contextMenu {
            Button("Connect") { open(item) }
            Button("Configure...") { configure(item) }
            Button(item.favorite ? "Remove from Favorites" : "Add to Favorites") { toggleFavorite(item) }
            if case .desktop(let desktop) = item.origin {
                Divider()
                Button("Remove", role: .destructive) { ui.desktopPendingRemoval = desktop }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(emptyTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(emptyDetail)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if !ui.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No results" }
        switch ui.page {
        case .favorites: return "No favorites"
        case .devices: return "No devices yet"
        case .apps: return "No apps"
        }
    }

    private var emptyDetail: String {
        if !ui.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Nothing matches “\(ui.query)”."
        }
        switch ui.page {
        case .favorites:
            return "Point at a device and click the star."
        case .devices:
            return "Add a work or school account, a workspace, or a PC."
        case .apps:
            return "Remote apps from your work or school account appear here."
        }
    }

    private var visibleSections: [DeviceSection] {
        let needle = ui.query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ item: DeviceItem) -> Bool {
            guard !needle.isEmpty else { return true }
            let haystack = "\(item.title) \(item.subtitle) \(item.badge) \(item.keywords)"
            return haystack.localizedCaseInsensitiveContains(needle)
        }
        func ordered(_ items: [DeviceItem]) -> [DeviceItem] {
            items.filter(matches).sorted { lhs, rhs in
                let order = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if order == .orderedSame { return lhs.id < rhs.id }
                let ascending = order == .orderedAscending
                return ui.sortAscending ? ascending : !ascending
            }
        }

        var sections: [DeviceSection] = []
        let workspace = ordered(workspaceItems)
        if !workspace.isEmpty {
            sections.append(DeviceSection(kind: .workspace, title: workspaceTitle, items: workspace))
        }
        let saved = ordered(savedItems)
        if !saved.isEmpty {
            sections.append(DeviceSection(kind: .saved, title: "Saved Devices", items: saved))
        }
        let apps = ordered(appItems)
        if !apps.isEmpty {
            sections.append(DeviceSection(kind: .apps, title: "Apps", items: apps))
        }
        return sections
    }

    private var workspaceTitle: String {
        if !model.workspaceName.isEmpty { return model.workspaceName }
        if !model.accountName.isEmpty { return model.accountName }
        return "Work or school"
    }

    private var workspaceItems: [DeviceItem] {
        guard ui.page != .apps else { return [] }
        guard ui.filter != .savedPCs else { return [] }
        return model.resources.compactMap { resource in
            if resource.kind == .remoteApp { return nil }
            if ui.page == .favorites && !preferences.favoriteResourceIDs.contains(resource.id) { return nil }
            if ui.filter == .desktops && resource.kind != .desktop { return nil }
            if ui.filter == .cloudPCs && resource.kind != .cloudPC { return nil }
            return DeviceItem(
                resource: resource,
                favorite: preferences.favoriteResourceIDs.contains(resource.id),
                displayName: publishedName(for: resource)
            )
        }
    }

    private var savedItems: [DeviceItem] {
        guard ui.page != .apps else { return [] }
        guard ui.filter == .all || ui.filter == .savedPCs else { return [] }
        return model.desktops.compactMap { desktop in
            if ui.page == .favorites && !desktop.isFavorite { return nil }
            return DeviceItem(desktop: desktop)
        }
    }

    private var appItems: [DeviceItem] {
        guard ui.page == .apps || ui.page == .favorites else { return [] }
        guard ui.page == .apps || ui.filter == .all else { return [] }
        return model.resources.compactMap { resource in
            guard resource.kind == .remoteApp else { return nil }
            if ui.page == .favorites && !preferences.favoriteResourceIDs.contains(resource.id) { return nil }
            return DeviceItem(
                resource: resource,
                favorite: preferences.favoriteResourceIDs.contains(resource.id),
                displayName: publishedName(for: resource)
            )
        }
    }

    private func publishedName(for resource: WorkspaceResource) -> String {
        preferences.publishedPC(id: resource.id)?.resolvedName(fallback: resource.name) ?? resource.name
    }

    private func isOpen(_ kind: DeviceSection.Kind) -> Bool {
        switch kind {
        case .workspace: return ui.workspaceSectionOpen
        case .saved: return ui.savedSectionOpen
        case .apps: return ui.appsSectionOpen
        }
    }

    private func setOpen(_ open: Bool, _ kind: DeviceSection.Kind) {
        switch kind {
        case .workspace: ui.workspaceSectionOpen = open
        case .saved: ui.savedSectionOpen = open
        case .apps: ui.appsSectionOpen = open
        }
    }

    private func beginAddPC() {
        model.editingDesktop = SavedDesktop(name: "", host: "", user: "")
        model.showingDesktopForm = true
    }

    private func open(_ item: DeviceItem) {
        ui.actionMenuID = nil
        ui.selectedID = item.id
        switch item.origin {
        case .resource(let resource):
            Task { await model.connect(resource) }
        case .desktop(let desktop):
            Task { await model.connect(desktop) }
        }
    }

    private func toggleFavorite(_ item: DeviceItem) {
        switch item.origin {
        case .resource(let resource):
            model.toggleFavorite(resourceID: resource.id)
        case .desktop(let desktop):
            model.toggleFavorite(desktop)
        }
    }

    private func toggleMenu(_ item: DeviceItem) {
        ui.selectedID = item.id
        if ui.suppressMenuOpenID == item.id {
            ui.suppressMenuOpenID = nil
            return
        }
        ui.actionMenuID = ui.actionMenuID == item.id ? nil : item.id
    }

    /// Outside clicks close the menu on mouse down. The more button then sees that close and would reopen it.
    private func dismissMenu(_ item: DeviceItem) {
        guard ui.actionMenuID == item.id else { return }
        ui.actionMenuID = nil
        ui.suppressMenuOpenID = item.id
        DispatchQueue.main.async {
            if ui.suppressMenuOpenID == item.id {
                ui.suppressMenuOpenID = nil
            }
        }
    }

    private func configure(_ item: DeviceItem) {
        ui.actionMenuID = nil
        ui.selectedID = item.id
        switch item.origin {
        case .resource(let resource):
            ui.resourcePendingConfigure = resource
        case .desktop(let desktop):
            model.editingDesktop = desktop
            model.showingDesktopForm = true
        }
    }
}

private final class LibraryUI: ObservableObject {
    @Published var page: LibraryPage = .devices
    @Published var layout: LibraryLayout = .grid
    @Published var filter: DeviceFilter = .all
    @Published var sortAscending = true
    @Published var query = ""
    @Published var selectedID: String?
    @Published var hoveredID: String?
    @Published var actionMenuID: String?
    @Published var suppressMenuOpenID: String?
    @Published var resourcePendingConfigure: WorkspaceResource?
    @Published var showingAdd = false
    @Published var showingAccount = false
    @Published var showingNotifications = false
    @Published var showingSettings = false
    @Published var showingWorkspaceURL = false
    @Published var workspaceSectionOpen = true
    @Published var savedSectionOpen = true
    @Published var appsSectionOpen = true
    @Published var desktopPendingRemoval: SavedDesktop?
}

private enum LibraryPage: Hashable {
    case favorites
    case devices
    case apps
}

private enum LibraryLayout: Hashable {
    case grid
    case list
}

private enum DeviceFilter: String, CaseIterable, Identifiable {
    case all
    case desktops
    case cloudPCs
    case savedPCs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .desktops: return "Desktops"
        case .cloudPCs: return "Cloud PCs"
        case .savedPCs: return "Saved PCs"
        }
    }
}

private struct DeviceSection: Identifiable {
    enum Kind: Hashable {
        case workspace
        case saved
        case apps
    }

    var kind: Kind
    var title: String
    var items: [DeviceItem]
    var id: Kind { kind }
}

private struct DeviceItem: Identifiable {
    enum Origin {
        case resource(WorkspaceResource)
        case desktop(SavedDesktop)
    }

    var id: String
    var title: String
    var subtitle: String
    var badge: String
    var seed: String
    var favorite: Bool
    var available: Bool
    var keywords: String
    var origin: Origin

    init(resource: WorkspaceResource, favorite: Bool, displayName: String) {
        id = "resource-\(resource.id)"
        title = displayName
        subtitle = ""
        switch resource.kind {
        case .desktop: badge = "AVD"
        case .cloudPC: badge = "Cloud PC"
        case .remoteApp: badge = "RemoteApp"
        }
        seed = resource.id
        self.favorite = favorite
        available = resource.kind != .remoteApp
        keywords = resource.name
        origin = .resource(resource)
    }

    init(desktop: SavedDesktop) {
        id = "desktop-\(desktop.id.uuidString)"
        title = desktop.listTitle
        subtitle = desktop.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? desktop.host : desktop.user
        badge = "PC Connection"
        seed = desktop.id.uuidString
        favorite = desktop.isFavorite
        available = false
        keywords = "\(desktop.host) \(desktop.user)"
        origin = .desktop(desktop)
    }
}

private struct DeviceTile: View {
    var item: DeviceItem
    var layout: LibraryLayout
    var selected: Bool
    var hovered: Bool
    var menuOpen: Bool
    var onSelect: () -> Void
    var onOpen: () -> Void
    var onToggleMenu: () -> Void
    var onDismissMenu: () -> Void
    var onToggleFavorite: () -> Void
    var onConfigure: () -> Void

    var body: some View {
        Group {
            if layout == .grid {
                card
                    .frame(width: 236, height: 148)
            } else {
                listRow
                    .frame(maxWidth: .infinity, minHeight: 78)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hovered || menuOpen {
                actionControls
                    .padding(.top, layout == .grid ? 8 : 10)
                    .padding(.trailing, 8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if menuOpen {
                ResourceActionMenu(onConnect: onOpen, onConfigure: onConfigure, onDismiss: onDismissMenu)
                    .padding(.top, 42)
                    .padding(.trailing, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var actionControls: some View {
        HStack(spacing: 6) {
            tileButton("ellipsis", label: "More", prominent: true, identifier: "device-more", action: onToggleMenu)
            tileButton(
                item.favorite ? "star.fill" : "star",
                label: item.favorite ? "Remove from Favorites" : "Add to Favorites",
                prominent: item.favorite,
                identifier: "device-favorite",
                action: onToggleFavorite
            )
        }
    }

    private func tileButton(_ symbol: String, label: String, prominent: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(prominent ? 0.96 : 0.82))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.black.opacity(prominent ? 0.55 : 0.32)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var accessibilityText: String {
        item.subtitle.isEmpty ? "\(item.title), \(item.badge)" : "\(item.title), \(item.subtitle), \(item.badge)"
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            DeviceWallpaper(seed: item.seed)
            if hovered {
                Color.white.opacity(0.06)
            }
            VStack(alignment: .leading, spacing: 0) {
                badge
                Spacer(minLength: 0)
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                }
            }
            .padding(12)
            if item.available {
                VStack {
                    Spacer()
                    Capsule()
                        .fill(Chrome.available)
                        .frame(width: 56, height: 4)
                        .padding(.bottom, 6)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(selectionStroke)
        .highPriorityGesture(TapGesture(count: 2).onEnded { onOpen() })
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .accessibilityLabel(accessibilityText)
    }

    private var listRow: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                DeviceWallpaper(seed: item.seed)
                badge.padding(6)
            }
            .frame(width: 112, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.available {
                Capsule()
                    .fill(Chrome.available)
                    .frame(width: 36, height: 3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovered || selected ? Color.white.opacity(0.06) : Color.white.opacity(0.03))
        )
        .overlay(selectionStroke)
        .highPriorityGesture(TapGesture(count: 2).onEnded { onOpen() })
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .accessibilityLabel(accessibilityText)
    }

    private var badge: some View {
        Text(item.badge)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private var selectionStroke: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Chrome.focus : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1)
    }
}

private struct DeviceWallpaper: View {
    var seed: String

    var body: some View {
        let palette = WallpaperPalette(seed: seed)
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(
                Path(bounds),
                with: .linearGradient(
                    Gradient(colors: [palette.base, palette.deep]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )
            for ribbon in palette.ribbons {
                var path = Path()
                let steps = 48
                path.move(to: point(0, ribbon: ribbon, size: size))
                for step in 1...steps {
                    path.addLine(to: point(CGFloat(step) / CGFloat(steps), ribbon: ribbon, size: size))
                }
                for step in stride(from: steps, through: 0, by: -1) {
                    let t = CGFloat(step) / CGFloat(steps)
                    var end = point(t, ribbon: ribbon, size: size)
                    end.y += size.height * ribbon.thickness
                    path.addLine(to: end)
                }
                path.closeSubpath()
                context.fill(path, with: .color(ribbon.color))
            }
        }
        .accessibilityHidden(true)
    }

    private func point(_ t: CGFloat, ribbon: WallpaperPalette.Ribbon, size: CGSize) -> CGPoint {
        let wave = sin((t * ribbon.frequency + ribbon.phase) * .pi * 2)
        return CGPoint(
            x: t * size.width,
            y: size.height * ribbon.center + wave * size.height * ribbon.amplitude
        )
    }
}

private struct WallpaperPalette {
    struct Ribbon {
        var color: Color
        var center: CGFloat
        var amplitude: CGFloat
        var frequency: CGFloat
        var phase: CGFloat
        var thickness: CGFloat
    }

    var base: Color
    var deep: Color
    var ribbons: [Ribbon]

    init(seed: String) {
        let hash = Self.fnv(seed)
        func unit(_ shift: Int) -> CGFloat {
            CGFloat((hash >> shift) & 0xff) / 255
        }
        let warm = (hash & 1) == 1
        if warm {
            base = Color(red: 0.62, green: 0.16, blue: 0.28)
            deep = Color(red: 0.16, green: 0.04, blue: 0.08)
            ribbons = [
                Ribbon(color: Color(red: 0.93, green: 0.28, blue: 0.38).opacity(0.92), center: 0.32 + unit(8) * 0.08, amplitude: 0.11, frequency: 1.15, phase: unit(16), thickness: 0.20),
                Ribbon(color: Color(red: 0.78, green: 0.18, blue: 0.32).opacity(0.88), center: 0.52, amplitude: 0.14, frequency: 1.0, phase: unit(24), thickness: 0.22),
                Ribbon(color: Color(red: 1.0, green: 0.48, blue: 0.28).opacity(0.8), center: 0.7, amplitude: 0.09, frequency: 1.35, phase: unit(32), thickness: 0.16)
            ]
        } else {
            base = Color(red: 0.16, green: 0.12, blue: 0.42)
            deep = Color(red: 0.05, green: 0.03, blue: 0.12)
            ribbons = [
                Ribbon(color: Color(red: 0.42, green: 0.36, blue: 0.95).opacity(0.9), center: 0.3 + unit(8) * 0.08, amplitude: 0.13, frequency: 1.1, phase: unit(16), thickness: 0.2),
                Ribbon(color: Color(red: 0.72, green: 0.28, blue: 0.72).opacity(0.82), center: 0.52, amplitude: 0.12, frequency: 1.25, phase: unit(24), thickness: 0.18),
                Ribbon(color: Color(red: 0.28, green: 0.22, blue: 0.78).opacity(0.9), center: 0.72, amplitude: 0.1, frequency: 1.0, phase: unit(32), thickness: 0.16)
            ]
        }
    }

    private static func fnv(_ text: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }
}

private final class AddMenuModel: ObservableObject {
    @Published var hover: Int?
}

private struct AddMenu: View {
    var onAccount: () -> Void
    var onWorkspace: () -> Void
    var onPC: () -> Void
    @StateObject private var model = AddMenuModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(0, "Add Work or School Account", "Add Windows 365 or Azure Virtual Desktop resources assigned to your account.", "workspace-sign-in", onAccount)
            row(1, "Add Workspace", "Add a workspace based on a URL provided by your admin.", "add-workspace", onWorkspace)
            row(2, "Add PC", "Add a connection to a physical PC or VM based on its name or IP address.", "add-saved-pc", onPC)
        }
        .padding(6)
        .frame(width: 360)
    }

    private func row(_ index: Int, _ title: String, _ detail: String, _ identifier: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(model.hover == index ? 0.92 : 0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(model.hover == index ? Chrome.menuBlue : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .onHover { hovering in
            model.hover = hovering ? index : (model.hover == index ? nil : model.hover)
        }
    }
}

private final class WorkspaceURLDraft: ObservableObject {
    @Published var url = ""
}

private struct WorkspaceURLSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = WorkspaceURLDraft()
    var onAdd: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Workspace")
                .font(.title2.weight(.semibold))
            Text("Add a workspace based on a URL provided by your admin.")
                .foregroundStyle(.secondary)
            TextField("https://", text: $draft.url)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    onAdd(draft.url)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!Self.isURL(draft.url))
            }
        }
        .padding(24)
        .frame(width: 460)
        .accessibilityIdentifier("add-workspace-form")
    }

    private static func isURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

enum Chrome {
    static let sidebar = Color(red: 0.145, green: 0.145, blue: 0.15)
    static let canvas = Color(red: 0.11, green: 0.11, blue: 0.115)
    static let raised = Color.white.opacity(0.08)
    static let selection = Color.white.opacity(0.13)
    static let menuBlue = Color(red: 0.0, green: 0.48, blue: 0.98)
    static let focus = Color(red: 0.23, green: 0.48, blue: 0.98)
    static let available = Color(red: 0.30, green: 0.86, blue: 0.40)
}

private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.115, alpha: 1)
            window.isMovableByWindowBackground = true
        }
    }
}

private final class MenuHover: ObservableObject {
    @Published var hover: Int?
}

private struct ResourceActionMenu: View {
    var onConnect: () -> Void
    var onConfigure: () -> Void
    var onDismiss: () -> Void
    @StateObject private var model = MenuHover()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(0, "Connect", onConnect)
            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(height: 1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            row(1, "Configure...", onConfigure)
        }
        .padding(6)
        .frame(width: 168)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.22, green: 0.22, blue: 0.24))
        )
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .background(ClickOutside(onOutside: onDismiss))
        .accessibilityIdentifier("device-actions")
    }

    private func row(_ index: Int, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(model.hover == index ? Chrome.menuBlue : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(index == 0 ? "device-connect" : "device-configure")
        .onHover { hovering in
            model.hover = hovering ? index : (model.hover == index ? nil : model.hover)
        }
    }
}

private final class ClickOutsideView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ClickOutside: NSViewRepresentable {
    var onOutside: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOutside: onOutside) }

    func makeNSView(context: Context) -> ClickOutsideView {
        let view = ClickOutsideView()
        context.coordinator.start(view)
        return view
    }

    func updateNSView(_ nsView: ClickOutsideView, context: Context) {
        context.coordinator.onOutside = onOutside
        context.coordinator.view = nsView
    }

    static func dismantleNSView(_ nsView: ClickOutsideView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onOutside: () -> Void
        weak var view: NSView?
        var monitor: Any?

        init(onOutside: @escaping () -> Void) {
            self.onOutside = onOutside
        }

        func start(_ view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let view = self.view, event.window === view.window else { return event }
                let target = Self.menuView(from: view)
                let point = target.convert(event.locationInWindow, from: nil)
                if !target.bounds.contains(point) {
                    let close = self.onOutside
                    DispatchQueue.main.async(execute: close)
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// The probe view can be zero-sized. The menu host is the nearest ancestor that is about the menu's size.
        private static func menuView(from view: NSView) -> NSView {
            if view.bounds.width >= 80 && view.bounds.height >= 40 { return view }
            var current = view.superview
            while let candidate = current {
                let width = candidate.bounds.width
                let height = candidate.bounds.height
                if width >= 80 && height >= 40 && width <= 320 && height <= 220 {
                    return candidate
                }
                if width > 320 { break }
                current = candidate.superview
            }
            return view
        }
    }
}

private final class PublishedPCDraft: ObservableObject {
    @Published var name: String
    @Published var credentials: PublishedCredentialMode
    @Published var useCustomSettings: Bool
    @Published var displayMode: SessionDisplayMode

    init(name: String, credentials: PublishedCredentialMode, useCustomSettings: Bool, displayMode: SessionDisplayMode) {
        self.name = name
        self.credentials = credentials
        self.useCustomSettings = useCustomSettings
        self.displayMode = displayMode
    }
}

private struct PublishedPCSheet: View {
    @ObservedObject var model: AppModel
    var resource: WorkspaceResource
    var onClose: () -> Void
    @StateObject private var draft: PublishedPCDraft

    init(model: AppModel, resource: WorkspaceResource, onClose: @escaping () -> Void) {
        self.model = model
        self.resource = resource
        self.onClose = onClose
        let existing = model.preferences.publishedPC(id: resource.id)
        _draft = StateObject(wrappedValue: PublishedPCDraft(
            name: existing?.resolvedName(fallback: resource.name) ?? resource.name,
            credentials: existing?.credentials ?? .askWhenRequired,
            useCustomSettings: existing?.useCustomSettings ?? false,
            displayMode: existing?.displayMode ?? .windowed
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 12) {
                labeledRow(nameLabel) {
                    TextField(resource.name, text: $draft.name)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(fieldShape)
                }
                labeledRow("Credentials") { credentialMenu }
                HStack(spacing: 12) {
                    Color.clear.frame(width: 108, height: 1)
                    Toggle("Use custom settings", isOn: $draft.useCustomSettings)
                        .toggleStyle(.checkbox)
                        .foregroundStyle(.white.opacity(0.82))
                }
                if draft.useCustomSettings {
                    labeledRow("Session") { sessionMenu }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                dialogButton("Cancel", fill: Color.white.opacity(0.14), action: onClose)
                    .keyboardShortcut(.cancelAction)
                dialogButton("Save", fill: Chrome.menuBlue, action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(Color(red: 0.22, green: 0.22, blue: 0.235))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 28, y: 12)
        .accessibilityIdentifier("published-pc-form")
    }

    private var title: String {
        resource.kind == .remoteApp ? "Configure RemoteApp" : "Configure Published PC"
    }

    private var nameLabel: String {
        resource.kind == .remoteApp ? "App name" : "PC name"
    }

    private var accountLabel: String {
        let user = model.accountUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty { return user }
        return model.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var credentialTitle: String {
        switch draft.credentials {
        case .askWhenRequired:
            return "Ask when required"
        case .signedInAccount:
            return accountLabel.isEmpty ? "Signed-in account" : accountLabel
        }
    }

    private var credentialMenu: some View {
        Menu {
            Button("Ask when required") { draft.credentials = .askWhenRequired }
            if !accountLabel.isEmpty {
                Button(accountLabel) { draft.credentials = .signedInAccount }
            }
        } label: {
            fieldLabel(credentialTitle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Credentials")
    }

    private var sessionMenu: some View {
        Menu {
            ForEach(SessionDisplayMode.allCases) { mode in
                Button(mode.title) { draft.displayMode = mode }
            }
        } label: {
            fieldLabel(draft.displayMode.title)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Session")
    }

    private func fieldLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(fieldShape)
    }

    private var fieldShape: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.black.opacity(0.38))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func labeledRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 108, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dialogButton(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
        }
        .buttonStyle(.plain)
    }

    private func save() {
        model.savePublishedPC(PublishedPCConfiguration(
            id: resource.id,
            name: draft.name,
            credentials: draft.credentials,
            useCustomSettings: draft.useCustomSettings,
            displayMode: draft.displayMode
        ))
        onClose()
    }
}

private final class DesktopDraft: ObservableObject {
    @Published var desktop: SavedDesktop
    @Published var password: String
    @Published var gatewayPassword: String

    init(desktop: SavedDesktop) {
        self.desktop = desktop
        password = KeychainStore.string(account: DesktopSecrets.passwordAccount(desktop.id)) ?? ""
        gatewayPassword = KeychainStore.string(account: DesktopSecrets.gatewayPasswordAccount(desktop.id)) ?? ""
    }
}

private struct DesktopForm: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: DesktopDraft

    init(model: AppModel, desktop: SavedDesktop) {
        self.model = model
        _draft = StateObject(wrappedValue: DesktopDraft(desktop: desktop))
    }

    var body: some View {
        Form {
            Text(isEditing ? "Configure PC" : "Add PC")
                .font(.title2.weight(.semibold))
            Text("Add a connection to a physical PC or VM based on its name or IP address.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Name", text: $draft.desktop.name)
            TextField("PC name", text: $draft.desktop.host)
            TextField("User", text: $draft.desktop.user)
            SecureField("Password", text: $draft.password)
            TextField("RD Gateway", text: $draft.desktop.gatewayHost)
            TextField("Gateway user", text: $draft.desktop.gatewayUser)
            SecureField("Gateway password", text: $draft.gatewayPassword)
            Picker("Session", selection: $draft.desktop.displayMode) {
                ForEach(SessionDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.saveDesktop(draft.desktop, password: draft.password, gatewayPassword: draft.gatewayPassword)
                    dismiss()
                }
                .disabled(draft.desktop.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .accessibilityIdentifier("saved-pc-form")
    }

    private var isEditing: Bool {
        model.desktops.contains(where: { $0.id == draft.desktop.id })
    }
}

private final class SignInDraft: ObservableObject {
    @Published var user: String
    @Published var password = ""
    @Published var remember = true

    init(user: String) {
        self.user = user
    }
}

private struct DesktopSignInSheet: View {
    @ObservedObject var model: AppModel
    let request: DesktopSignInRequest
    @StateObject private var draft: SignInDraft
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, request: DesktopSignInRequest) {
        self.model = model
        self.request = request
        _draft = StateObject(wrappedValue: SignInDraft(user: request.user))
    }

    var body: some View {
        Form {
            Text("Sign in")
                .font(.title2.weight(.semibold))
            Text("\(request.desktop.listTitle) only accepts a connection after a user name and password. Network Level Authentication does not show the Windows sign-in screen until those are provided.")
            TextField("User", text: $draft.user)
            SecureField("Password", text: $draft.password)
            Toggle("Remember for this PC", isOn: $draft.remember)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect") {
                    model.connect(request.desktop, user: draft.user, password: draft.password, remember: draft.remember)
                    dismiss()
                }
                .disabled(draft.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .accessibilityIdentifier("saved-pc-sign-in")
    }
}

struct DesktopSignInRequest: Identifiable {
    let desktop: SavedDesktop
    let user: String
    var id: UUID { desktop.id }
}
