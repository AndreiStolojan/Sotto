import SwiftUI

/// Settings rows for the running build and the manual update check. Nothing is sent until the user presses Check.
struct UpdateSettingsView: View {
    private enum CheckState: Equatable {
        case idle
        case checking
        case finished(Result<UpdateCheck.Outcome, UpdateCheck.Failure>)
    }

    private let build = AppBuild.current
    @State private var state = CheckState.idle
    @State private var updateError: String?

    var body: some View {
        LabeledContent("Version") {
            Text(build.summary)
                .textSelection(.enabled)
        }

        LabeledContent {
            HStack(spacing: 8) {
                status

                if case .finished(.success(.updateAvailable)) = state, let channel = build.channel {
                    Button("Copy Command") {
                        _ = ClipboardManager.copyToClipboard(channel.installCommand)
                    }
                    Button("Update") {
                        update(channel)
                    }
                } else {
                    Button("Check") {
                        check()
                    }
                    .disabled(state == .checking || build.commit == nil || build.channel == nil)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if state == .checking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Check for Updates")
                InfoTip("Asks GitHub for the latest commit on this channel's branch. Sotto checks only when you press Check. Update opens Terminal and runs the install command, which rebuilds the app from source.")
            }
        }
        .alert(
            "Update Failed",
            isPresented: Binding(get: { updateError != nil }, set: { if !$0 { updateError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(updateError ?? "")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .idle, .checking:
            if build.commit == nil || build.channel == nil {
                Text("Built without git, nothing to compare")
                    .foregroundStyle(.secondary)
            }
        case .finished(.success(.upToDate)):
            Text("Up to date")
                .foregroundStyle(.secondary)
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(AppTheme.Status.positive)
        case .finished(.success(.updateAvailable(let commit))):
            Text("Update available: \(UpdateCheck.shortCommit(commit))")
                .foregroundStyle(.secondary)
        case .finished(.failure(let failure)):
            Text(failure.message)
                .foregroundStyle(.secondary)
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(AppTheme.Status.warningStrong)
        }
    }

    private func check() {
        guard let commit = build.commit, let channel = build.channel else { return }
        state = .checking
        Task {
            state = .finished(await UpdateCheck.check(commit: commit, channel: channel))
        }
    }

    private func update(_ channel: UpdateChannel) {
        do {
            let script = try UpdateCheck.writeUpdateScript(for: channel)
            if !NSWorkspace.shared.open(script) {
                updateError = "Terminal could not open the update script. Run the install command yourself:\n\(channel.installCommand)"
            }
        } catch {
            updateError = error.localizedDescription
        }
    }
}
