import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("MacID: \(model.statusSummary)")

        if !model.isReady {
            Divider()
            Button("Finish Setting Up\u{2026}") { open() }
        }

        Divider()

        Button("Open MacID\u{2026}") { open() }

        if Updater.shared.isConfigured {
            Button("Check for Updates\u{2026}") { Updater.shared.checkForUpdates() }
        }

        Divider()

        Button("Quit MacID") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open() {
        if !Presentation.focusExistingWindow() { openWindow(id: WindowID.main) }
    }
}
