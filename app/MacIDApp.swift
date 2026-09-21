import AppKit
import SwiftUI

enum WindowID {
    static let main = "macid-main"
}

@main
struct MacIDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("MacID", id: WindowID.main) {
            MainWindow()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 600)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            MenuBarLabel(active: model.isReady)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The menu bar icon; also lends `openWindow` to code outside views.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    let active: Bool

    var body: some View {
        Image(nsImage: BrandMark.menuBarImage(active: active))
            .task { Presentation.openMainWindow = { openWindow(id: WindowID.main) } }
    }
}

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.onboardingFinished {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .textSelection(.enabled)
        .onDisappear { Presentation.syncActivationPolicy() }
    }
}

/// Keeps the app running with no windows open and manages its Dock presence.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppModel.shared.bootstrap()
            _ = Updater.shared
            Presentation.syncActivationPolicy()
            if !Presentation.launchedAtLogin || !AppModel.shared.isReady {
                await Presentation.showMainWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Task { @MainActor in
                if !Presentation.focusExistingWindow() { await Presentation.showMainWindow() }
            }
        }
        return true
    }
}

@MainActor
enum Presentation {
    /// Shows the app in the Dock until face unlock is working, then only in the menu bar.
    static func syncActivationPolicy() {
        let model = AppModel.shared
        let wanted: NSApplication.ActivationPolicy =
            (model.onboardingFinished && model.isReady) ? .accessory : .regular
        if NSApp.activationPolicy() != wanted {
            NSApp.setActivationPolicy(wanted)
        }
    }

    /// True when launchd started this process as a login item.
    static var launchedAtLogin: Bool {
        let name = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? ""
        return !name.isEmpty && name != "0"
    }

    /// Set by the menu bar label once SwiftUI has built it.
    static var openMainWindow: (() -> Void)?

    /// Shows the main window, waiting briefly if the open action is not yet available.
    static func showMainWindow() async {
        if focusExistingWindow() { return }
        for _ in 0..<40 {
            if let open = openMainWindow {
                NSApp.setActivationPolicy(.regular)
                open()
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Brings the app forward. Returns true if an existing window was reused.
    @discardableResult
    static func focusExistingWindow() -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }
}
