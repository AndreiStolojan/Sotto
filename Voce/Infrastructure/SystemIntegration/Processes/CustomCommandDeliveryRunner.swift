import Foundation

struct CustomCommandDeliveryContext {
    let transcript: String

    var standardInput: String {
        transcript
    }

    var environment: [String: String] {
        [
            "VOCE_TRANSCRIPT": transcript
        ]
    }
}

struct CustomCommandDeliveryResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum CustomCommandDeliveryError: Error, LocalizedError {
    case commandNotConfigured
    case noTextToDeliver
    case launchFailed(String)
    case timeout(seconds: Double)
    case nonZeroExit(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .commandNotConfigured:
            return String(localized: "Custom command is empty.")
        case .noTextToDeliver:
            return String(localized: "No transcription text was available for the custom command.")
        case .launchFailed(let message):
            return String(format: String(localized: "Custom command could not start: %@"), message)
        case .timeout(let seconds):
            return String(format: String(localized: "Custom command timed out after %.0f seconds."), seconds)
        case .nonZeroExit(let status, let stderr):
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if details.isEmpty {
                return String(format: String(localized: "Custom command exited with status %d."), status)
            }
            return String(
                format: String(localized: "Custom command exited with status %d: %@"), status,
                String(details.prefix(300)))
        }
    }
}

/// Runs the user's delivery command with the transcript on stdin and in `VOCE_TRANSCRIPT`.
/// Output is capped per stream, and timeout or Task cancellation terminates the command's process tree.
enum CustomCommandDeliveryRunner {
    static func run(
        command: String,
        timeout: TimeInterval,
        context: CustomCommandDeliveryContext
    ) async throws -> CustomCommandDeliveryResult {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw CustomCommandDeliveryError.commandNotConfigured
        }

        let environment = await ShellCommandEnvironment.resolveCommandEnvironment(
            additionalEnvironment: context.environment
        )

        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", trimmedCommand],
                environment: environment,
                standardInput: Data(context.standardInput.utf8),
                timeout: timeout
            )
        } catch ProcessRunner.Failure.timedOut {
            throw CustomCommandDeliveryError.timeout(seconds: timeout)
        } catch ProcessRunner.Failure.launchFailed(let message) {
            throw CustomCommandDeliveryError.launchFailed(message)
        }

        let stdout = output.stdoutString
        let stderr = output.stderrString
        guard output.succeeded else {
            throw CustomCommandDeliveryError.nonZeroExit(status: output.status, stderr: stderr)
        }

        return CustomCommandDeliveryResult(status: output.status, stdout: stdout, stderr: stderr)
    }
}
