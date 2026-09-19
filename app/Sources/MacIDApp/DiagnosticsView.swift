import SwiftUI
import MacIDCore

/// What `macid status` and `macid doctor` used to print.
///
/// When the lock screen stops recognizing you, it does so silently: you press
/// Return and nothing happens. This is the one place that says why. The
/// configuration checks are live; the camera checks cost a camera session, so
/// they run only when asked for.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostics").font(.headline)
                    Text("Every moving part, and which one is broken.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyToPasteboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy this report to the clipboard")
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    CheckList(title: "SETUP", checks: model.checks)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("CAMERA")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if model.runningCameraCheck {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(model.cameraChecks.isEmpty ? "Run Check" : "Run Again") {
                                    Task { await model.runCameraCheck() }
                                }
                                .font(.callout)
                            }
                        }

                        if model.cameraChecks.isEmpty && !model.runningCameraCheck {
                            Text("Opens the camera for a moment, looks for your face, and reports "
                                 + "how close the match was.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            CheckRows(checks: model.cameraChecks)
                        }
                    }
                }
                .padding(24)
            }
        }
        .onAppear { model.refresh() }
    }

    private func copyToPasteboard() {
        let lines = (model.checks + model.cameraChecks).map { check in
            "\(check.name): \(check.value)" + (check.remedy.map { "  — \($0)" } ?? "")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

private struct CheckList: View {
    let title: String
    let checks: [Diagnostics.Check]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            CheckRows(checks: checks)
        }
    }
}

private struct CheckRows: View {
    let checks: [Diagnostics.Check]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                if index > 0 { Divider() }
                row(check)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ check: Diagnostics.Check) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(check.health))
                .foregroundStyle(tint(check.health))

            VStack(alignment: .leading, spacing: 2) {
                Text(check.name)
                if let remedy = check.remedy {
                    Text(remedy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            Text(check.value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                // Paths and distances are the whole point of this screen, so
                // let them be selected and pasted into a bug report.
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func symbol(_ health: Diagnostics.Health) -> String {
        switch health {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.circle.fill"
        }
    }

    private func tint(_ health: Diagnostics.Health) -> Color {
        switch health {
        case .ok: return .green
        case .warning: return .orange
        case .bad: return .red
        }
    }
}
