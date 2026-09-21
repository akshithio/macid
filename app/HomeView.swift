import SwiftUI
import MacIDCore

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updater = Updater.shared
    @State private var sheet: Sheet?
    @State private var confirmingOff = false
    @State private var confirmingUninstall = false
    @State private var removing: Enrollment.Face?
    @State private var naming = false
    @State private var newFaceName = "Me"

    /// A default face name that does not collide with an existing one.
    private var suggestedName: String {
        let taken = Set(model.faces.map { $0.name.lowercased() })
        if !taken.contains("me") { return "Me" }
        var n = 2
        while taken.contains("face \(n)") { n += 1 }
        return "Face \(n)"
    }

    enum Sheet: Identifiable {
        case enroll(String)
        case test
        case password
        var id: String {
            switch self {
            case .enroll(let name): return "enroll:\(name)"
            case .test: return "test"
            case .password: return "password"
            }
        }
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
                    unlock
                    recognition
                    general
                    removal
                }
                .padding(24)
            }
        }
        .sheet(item: $sheet) { which in
            VStack(spacing: 20) {
                switch which {
                case .enroll(let name):
                    Text(model.faces.contains { $0.name == name }
                         ? "Re-enroll \(name)" : "Add \(name)")
                        .font(.title2.weight(.semibold))
                    EnrollPanel(name: name) { sheet = nil; model.refresh() }
                case .test:
                    Text("Test Recognition").font(.title2.weight(.semibold))
                    TestPanel()
                case .password:
                    PasswordPanel { sheet = nil }
                }
                if case .password = which {} else {
                    Button("Close") { sheet = nil; model.refresh() }
                        .keyboardShortcut(.cancelAction)
                }
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
        .alert("Add a face", isPresented: $naming) {
            TextField("Name", text: $newFaceName)
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                let name = newFaceName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { if await model.ensureCamera() { sheet = .enroll(name) } }
            }
        } message: {
            Text("What should MacID call this face? Enrolling one that is already "
                 + "on the list replaces it.")
        }
        .alert("Uninstall MacID?", isPresented: $confirmingUninstall) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { Task { await model.uninstallEverything() } }
        } message: {
            Text("This removes face unlock from the lock screen, deletes your enrolled "
                 + "faces, and moves MacID.app itself. Your Mac will unlock with your "
                 + "password as it did before. MacID will quit when it is done.")
        }
        .alert("Remove this face?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let f = removing { model.removeFace(f.id) }
                removing = nil
            }
        } message: {
            Text(removing.map { "MacID will stop recognizing \($0.name)." } ?? "")
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
                Task { if await model.ensureCamera() { sheet = .test } }
            } label: {
                Label("Test", systemImage: "viewfinder")
            }
            .disabled(!model.isEnrolled)
            .help(model.isEnrolled
                  ? "Check that MacID recognizes you"
                  : "Enroll your face first")
        }
        .padding(20)
    }

    private var face: some View {
        Section(title: "FACES") {
            if model.faces.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.square")
                        .font(.title3).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No face enrolled")
                        Text(faceDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else {
                ForEach(Array(model.faces.enumerated()), id: \.element.id) { index, face in
                    if index > 0 { Divider() }
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.square")
                            .font(.title3).foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(face.name)
                            Text("\(face.samples.count) samples")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Re-enroll\u{2026}") {
                            Task { if await model.ensureCamera() { sheet = .enroll(face.name) } }
                        }
                        Button {
                            removing = face
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(face.name)")
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("Add a Face\u{2026}") {
                    newFaceName = suggestedName
                    naming = true
                }
                Spacer()
            }
            Text("Several faces can unlock your Mac. Add yourself again in glasses, "
                 + "or add someone you want to let in. Unlocking matches the closest "
                 + "of them all.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var faceDetail: String {
        switch model.camera {
        case .denied:
            return "MacID has no camera access \u{2014} enrolling will show you where to turn it on"
        case .notDetermined:
            return "Enrolling will ask for camera access"
        case .authorized:
            return model.isEnrolled ? "\(model.sampleCount) samples" : "Enroll to use face unlock"
        }
    }

    /// Where MacID can stand in for your password, and what each needs.
    private var unlock: some View {
        Section(title: "UNLOCK WITH YOUR FACE") {
            if model.needsFullDiskAccess {
                setting(caption: "macOS protects the lock screen's settings. Turn on MacID "
                        + "under Full Disk Access, then try again.") {
                    statusRow(ok: false, okText: "", problemText: "Needs Full Disk Access") {
                        Button("Open Settings\u{2026}") { FullDiskAccess.openSettingsPane() }
                    }
                }

                Divider()
            }

            if model.moduleOutdated {
                setting(caption: "MacID was updated, but the part of it the lock screen loads "
                        + "is still the old version. macOS will ask for your password once.") {
                    statusRow(ok: false, okText: "", problemText: "Lock screen module needs updating") {
                        if model.busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Update\u{2026}") { Task { await model.updateModule() } }
                        }
                    }
                }

                Divider()
            }

            statusRow(ok: model.lockScreenWired,
                      okText: "Lock screen",
                      problemText: model.lockScreenProblem.map { "Lock screen needs repair: \($0)" }
                          ?? "Lock screen is off") {
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

            setting(caption: "A face unlock skips your password, and your Keychain needs it. "
                    + "It is sealed to this Mac's Secure Enclave and used for nothing else.") {
                statusRow(ok: model.passwordSaved,
                          okText: "Mac password saved",
                          problemText: "Needs your Mac password") {
                    if model.passwordSaved {
                        Button("Change\u{2026}") { sheet = .password }
                        Button("Forget") { model.forgetPassword() }
                    } else {
                        Button("Add\u{2026}") { sheet = .password }
                    }
                }
            }

            Divider()

            statusRow(ok: model.camera == .authorized,
                      okText: "Camera access",
                      problemText: "Camera access is off, so MacID can't see you") {
                if model.camera == .notDetermined {
                    Button("Allow") { Task { await model.requestCamera() } }
                } else if model.camera == .denied {
                    Button("Fix") { CameraAccess.openSettingsPane() }
                }
            }

            if !model.agentRunning {
                Divider()
                statusRow(ok: false, okText: "", problemText: agentProblem) { EmptyView() }
            }
        }
    }

    private var agentProblem: String {
        if case .stopped(let why?) = model.agentHost { return "Not running: \(why)" }
        return "Not running"
    }

    private var recognition: some View {
        Section(title: "RECOGNITION") {
            SensitivityControl()

            Divider()

            setting(caption: model.config.liveness == .blink
                    ? "A still photo can't unlock your Mac. Unlocking waits for your next blink."
                    : "Unlocks as soon as it sees you. A good photo of you could also unlock it.") {
                Toggle("Require a blink", isOn: Binding(
                    get: { model.config.liveness == .blink },
                    set: { model.setRequireBlink($0) }))
            }

            Divider()

            setting(caption: model.config.warmWithDisplay
                    ? "Faster unlocks. The camera light comes on while the lock screen is showing."
                    : "The camera light only comes on when you press Return, about a second slower.") {
                Picker("Start the camera", selection: Binding(
                    get: { model.config.warmWithDisplay },
                    set: { model.setWarmWithDisplay($0) })) {
                    Text("When the screen wakes").tag(true)
                    Text("When I press Return").tag(false)
                }
            }
        }
    }

    private var general: some View {
        Section(title: "GENERAL") {
            setting(caption: "Face unlock runs inside MacID, so it has to be open. "
                    + "You can close this window; MacID stays in the menu bar.") {
                Toggle("Open MacID when I log in", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                if LoginItem.needsUserApproval {
                    Button("Allow in Login Items\u{2026}") { LoginItem.openLoginItemsSettings() }
                        .font(.callout)
                }
            }

            if Updater.shared.isConfigured {
                Divider()

                HStack(spacing: 8) {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updater.automaticallyChecks },
                        set: { updater.setAutomaticallyChecks($0) }))
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                }
            }

            Divider()

            HStack(spacing: 10) {
                if model.collectingDiagnostics {
                    ProgressView().controlSize(.small)
                    Text("Checking\u{2026}").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Copy Diagnostics") { Task { await model.copyDiagnostics() } }
                    if model.diagnosticsCopied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
    }

    private var removal: some View {
        Section(title: "UNINSTALL") {
            setting(caption: "Takes MacID out of the lock screen, deletes your faces and "
                    + "saved password, and deletes the app.") {
                HStack(spacing: 8) {
                    Text("Remove MacID from this Mac")
                    Spacer()
                    if model.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Uninstall\u{2026}") { confirmingUninstall = true }
                    }
                }
            }
        }
    }

    /// A control with a one-line caption under it.
    private func setting<Control: View>(caption: String,
                                        @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            control()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

/// Asks for the Mac password and keeps it only if it verifies.
private struct PasswordPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var problem: String?
    @State private var saving = false
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Mac Password").font(.title2.weight(.semibold))
            Text("The one you type at the lock screen. MacID uses it to unlock your "
                 + "Keychain after it lets you in by face, so your saved passwords, "
                 + "tokens and signing keys keep working.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || saving)
            }
        }
        .frame(width: 360)
    }

    private func save() {
        guard !password.isEmpty, !saving else { return }
        saving = true
        Task {
            problem = await model.savePassword(password)
            saving = false
            if problem == nil { password = ""; done() }
        }
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
