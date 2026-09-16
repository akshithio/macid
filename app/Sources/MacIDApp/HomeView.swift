import SwiftUI
import MacIDCore

/// The steady state: whether face unlock is working, the face it knows, and
/// the few switches that matter.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sheet: Sheet?
    @State private var confirmingOff = false
    @State private var confirmingDelete = false

    enum Sheet: Identifiable {
        case enroll, test
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let error = model.actionError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    face
                    lockScreen
                    settings
                    Label("You can close this window. MacID keeps running in the menu bar.",
                          systemImage: "menubar.arrow.up.rectangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
        .sheet(item: $sheet) { which in
            VStack(spacing: 20) {
                switch which {
                case .enroll:
                    Text("Re-enroll Your Face").font(.title2.weight(.semibold))
                    EnrollPanel { sheet = nil; model.refresh() }
                case .test:
                    Text("Test Recognition").font(.title2.weight(.semibold))
                    TestPanel()
                }
                Button("Close") { sheet = nil; model.refresh() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(28)
        }
        .alert("Turn off face unlock?", isPresented: $confirmingOff) {
            Button("Cancel", role: .cancel) {}
            Button("Turn Off", role: .destructive) { Task { await model.turnOffLockScreen() } }
        } message: {
            Text("MacID will be removed from the lock screen and your Mac will only unlock "
                 + "with your password. macOS will ask for your password to make the change.")
        }
        .alert("Delete face data?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { model.deleteFaceData() }
        } message: {
            Text("MacID will stop recognizing you until you enroll again.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("MacID").font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.isReady ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(model.statusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                sheet = .test
            } label: {
                Label("Test", systemImage: "viewfinder")
            }
            .disabled(!model.isEnrolled || model.camera != .authorized)
        }
        .padding(20)
    }

    private var face: some View {
        Section(title: "FACE") {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.square")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isEnrolled ? "Face enrolled" : "No face enrolled")
                    Text(model.isEnrolled
                         ? "\(model.sampleCount) samples"
                         : "Enroll to use face unlock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(model.isEnrolled ? "Re-enroll\u{2026}" : "Enroll\u{2026}") { sheet = .enroll }
                    .disabled(model.camera != .authorized)

                if model.isEnrolled {
                    Button {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete face data")
                }
            }
        }
    }

    private var lockScreen: some View {
        Section(title: "LOCK SCREEN") {
            statusRow(ok: model.lockScreenWired,
                      okText: "Face unlock is on at the lock screen",
                      problemText: model.lockScreenProblem.map { "Needs repair: \($0)" }
                          ?? "Face unlock is off at the lock screen") {
                if model.busy {
                    ProgressView().controlSize(.small)
                } else if model.lockScreenWired {
                    Button("Turn Off\u{2026}") { confirmingOff = true }
                } else {
                    Button(model.lockScreenProblem == nil ? "Turn On\u{2026}" : "Repair\u{2026}") {
                        Task { await model.turnOnLockScreen() }
                    }
                }
            }

            Divider()

            statusRow(ok: model.camera == .authorized,
                      okText: "Camera access granted",
                      problemText: "Camera access is off \u{2014} MacID can't see you") {
                if model.camera == .notDetermined {
                    Button("Allow") { Task { await model.requestCamera() } }
                } else if model.camera == .denied {
                    Button("Fix") { CameraAccess.openSettingsPane() }
                }
            }

            Divider()

            statusRow(ok: model.agentRunning,
                      okText: model.agentHost == .app
                          ? "Running in MacID"
                          : "Running as a background service",
                      problemText: agentProblem) { EmptyView() }
        }
    }

    private var agentProblem: String {
        if case .stopped(let why?) = model.agentHost { return "Not running: \(why)" }
        return "Not running"
    }

    private var settings: some View {
        Section(title: "SETTINGS") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Open MacID when I log in", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                Text("Face unlock runs inside MacID, so it has to be open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if LoginItem.needsUserApproval {
                    Button("Allow in Login Items\u{2026}") { LoginItem.openLoginItemsSettings() }
                        .font(.callout)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Require a blink", isOn: Binding(
                    get: { model.config.liveness == .blink },
                    set: { model.setRequireBlink($0) }))
                Text(model.config.liveness == .blink
                     ? "A still photo can't unlock your Mac. Unlocking waits for your next natural blink."
                     : "Unlocks as soon as it sees you with your eyes open. A good photo of your face could also unlock it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusRow<Trailing: View>(ok: Bool, okText: String, problemText: String,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(ok ? okText : problemText)
            Spacer()
            trailing()
        }
        .font(.callout)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
