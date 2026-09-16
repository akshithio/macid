import SwiftUI

/// The status item's menu.
///
/// A real NSMenu (`.menuBarExtraStyle(.menu)`), not a custom panel, so it has
/// the native hover highlight and keyboard navigation and looks like every
/// other menu in the bar. State is shown as disabled items, which is how macOS
/// menus show information that is not an action.
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

        Divider()

        if model.agentHost == .app {
            Text("Quitting turns off face unlock")
        }
        Button("Quit MacID") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open() {
        if !Presentation.focusExistingWindow() { openWindow(id: WindowID.main) }
    }
}
