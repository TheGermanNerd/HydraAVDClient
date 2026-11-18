import HydraRdpCore
import SwiftUI

@main
struct HydraRdpApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Hydra AVD Client") {
            RootView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add PC") {
                    model.editingDesktop = SavedDesktop(name: "", host: "", user: "")
                    model.showingDesktopForm = true
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Add Work or School Account") {
                    Task { await model.signIn() }
                }
            }
        }
    }
}

private struct RootView: View {
    @ObservedObject var model: AppModel
    @StateObject private var form: InstallerForm

    init(model: AppModel) {
        self.model = model
        _form = StateObject(wrappedValue: InstallerForm(model: model))
    }

    var body: some View {
        if model.showingInstaller {
            InstallerView(model: model, form: form)
        } else {
            LibraryView(model: model)
        }
    }
}
