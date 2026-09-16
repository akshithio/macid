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
            Image(nsImage: BrandMark.menuBarImage(active: model.isReady))
        }
        .menuBarExtraStyle(.menu)
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
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }

    /// Closing the window must not stop face unlock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { _ = Presentation.focusExistingWindow() } }
        return true
    }
}

@MainActor
enum Presentation {
    /// Set up and running belongs in the menu bar, not the Dock. During setup
    /// it is a normal app so its window can take focus.
    static func syncActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy =
            AppModel.shared.onboardingFinished ? .accessory : .regular
        if NSApp.activationPolicy() != wanted {
            NSApp.setActivationPolicy(wanted)
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
