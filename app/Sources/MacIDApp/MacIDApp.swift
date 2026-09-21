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

/// The menu bar icon, and the one place that can hand out `openWindow`.
///
/// Opening a SwiftUI `Window` scene needs the environment action, which only
/// exists inside a view. The menu bar label is the only view guaranteed to be
/// alive whether or not a window is open, so it is what lends the action to
/// the parts of the app that are not views — chiefly the launch path, which
/// has to be able to show the window when SwiftUI has restored it as closed.
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
                // Two tabs rather than one long scroll: the second one is only
                // ever opened when something is wrong, and filling it in costs
                // a camera session.
                TabView {
                    HomeView()
                        .tabItem { Label("Face Unlock", systemImage: "faceid") }
                    DiagnosticsView()
                        .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                }
            } else {
                OnboardingView()
            }
        }
        // Drop to menu-bar-only when the window closes, never while it is on
        // screen: vanishing from the Dock mid-setup reads as a crash.
        .onDisappear { Presentation.syncActivationPolicy() }
    }
}

/// Process-level behaviour SwiftUI scenes can't express: staying alive with no
/// windows open, since the agent lives in this process, and leaving the Dock
/// once setup is done.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppModel.shared.bootstrap()
            Presentation.syncActivationPolicy()
            // SwiftUI restores the window as closed if it was closed last
            // time. Staying closed is right only when launchd started us at
            // login and there is nothing wrong. If someone opened MacID
            // themselves, they want to see MacID — an app that does nothing
            // visible when you open it looks broken.
            if !Presentation.launchedAtLogin || !AppModel.shared.isReady {
                await Presentation.showMainWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }

    /// Closing the window must not stop face unlock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the app when its window is closed must open one, not silently
    /// do nothing.
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
    /// Set up and running belongs in the menu bar, not the Dock. During setup
    /// it is a normal app so its window can take focus.
    ///
    /// "Working" is the condition, not "has been through setup once". If the
    /// enrollment goes missing or the camera grant is withdrawn, face unlock is
    /// not running, and an app that hides in the menu bar while broken gives
    /// the user nowhere to go — opening it appears to do nothing at all.
    static func syncActivationPolicy() {
        let model = AppModel.shared
        let wanted: NSApplication.ActivationPolicy =
            (model.onboardingFinished && model.isReady) ? .accessory : .regular
        if NSApp.activationPolicy() != wanted {
            NSApp.setActivationPolicy(wanted)
        }
    }

    /// True when launchd started this process as a login item, rather than the
    /// user opening the app.
    ///
    /// launchd sets `XPC_SERVICE_NAME` for the jobs it starts; a launch from
    /// Finder, the Dock or `open` leaves it unset or "0". The default when it
    /// is ambiguous is to treat the launch as deliberate and show the window,
    /// because hiding from someone who asked for the app is the worse mistake.
    static var launchedAtLogin: Bool {
        let name = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? ""
        return !name.isEmpty && name != "0"
    }

    /// Lent by the menu bar label once SwiftUI has built it.
    static var openMainWindow: (() -> Void)?

    /// Show the window, whether or not one already exists. The action comes
    /// from a view, so at launch it may not have been handed over yet; wait
    /// briefly rather than dropping the request on the floor.
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

    /// Brings the app forward, returning true if an existing window was reused.
    /// False means the caller should open a fresh scene, which only a SwiftUI
    /// view can do.
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
