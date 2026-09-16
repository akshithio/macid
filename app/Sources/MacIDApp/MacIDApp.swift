import SwiftUI
import AppKit
import MacIDCore

@main
struct MacIDApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            // The icon is a status readout, not branding: filled means the lock
            // screen is actually wired up, outline means something is missing.
            Image(systemName: model.isFullyArmed ? "faceid" : "faceid")
                .symbolRenderingMode(.hierarchical)
                .opacity(model.isFullyArmed ? 1.0 : 0.45)
        }
        .menuBarExtraStyle(.window)

        Window("Enroll Your Face", id: "enroll") {
            EnrollView().environmentObject(model)
        }
        .windowResizability(.contentSize)

        Window("MacID Settings", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            checklist
            if !model.isFullyArmed {
                Divider().padding(.vertical, 8)
                setupHint
            }
            Divider().padding(.vertical, 8)
            actions
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "faceid")
                .font(.system(size: 26))
                .foregroundStyle(model.isFullyArmed ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacID").font(.headline)
                Text(model.isFullyArmed ? "Face unlock is active"
                                        : "Setup incomplete")
                    .font(.caption)
                    .foregroundStyle(model.isFullyArmed ? .green : .orange)
            }
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 7) {
            row("Face enrolled",
                ok: model.isEnrolled,
                detail: model.isEnrolled ? "\(model.enrolledSamples) samples" : "not yet")
            row("Agent running",
                ok: model.agent == .running,
                detail: model.agent.label)
            row("Lock screen wired",
                ok: model.pamInstalled,
                detail: model.pamInstalled ? "screensaver_new" : "not installed")
            row("Liveness check",
                ok: model.config.requireBlink,
                detail: model.config.requireBlink ? "blink required" : "OFF — photo-spoofable")
        }
    }

    private func row(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.system(size: 13))
            Text(title).font(.callout)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// When the PAM stack is not wired the app cannot fix it itself — that edit
    /// needs root. Handing over the exact command is more honest than a button
    /// that silently asks for a password.
    private var setupHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To finish setup").font(.caption).bold()
            Text(!model.isEnrolled ? "Enroll your face first, then run:"
                                   : "Run this in Terminal:")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("sudo macid install")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("sudo macid install", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            .padding(6)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var actions: some View {
        VStack(spacing: 4) {
            Button {
                openWindow(id: "enroll")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(model.isEnrolled ? "Re-enroll Face…" : "Enroll Face…",
                      systemImage: "person.crop.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Divider().padding(.vertical, 4)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit MacID", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }
}
