import Foundation

enum LocalCLITemplate: String, CaseIterable, Identifiable {
    case pi
    case claude
    case codex
    case copilot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pi: return "Pi"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .copilot: return "Copilot"
        }
    }

    var commandTemplate: String {
        switch self {
        case .pi:
            return "pi -ne -ns -p --no-tools --system-prompt \"$VOCE_SYSTEM_PROMPT\" \"$VOCE_USER_PROMPT\""
        case .claude:
            return "claude -p --model claude-sonnet-5 --effort low \"$VOCE_FULL_PROMPT\""
        case .codex:
            return
                "codex exec -m gpt-5.6-luna -c model_reasoning_effort=low --skip-git-repo-check --ephemeral \"$VOCE_FULL_PROMPT\""
        case .copilot:
            return "copilot -p \"$VOCE_FULL_PROMPT\" -s --no-ask-user --available-tools=__none__ 2>/dev/null"
        }
    }
}

final class LocalCLIService {
    static let commandTemplateKey = "localCLICommandTemplate"
    static let selectedTemplateKey = "localCLISelectedTemplate"
    static let timeoutSecondsKey = "localCLITimeoutSeconds"
    static let defaultTimeoutSeconds: Double = 45

    var commandTemplate: String {
        didSet {
            UserDefaults.standard.set(commandTemplate, forKey: Self.commandTemplateKey)
        }
    }

    var selectedTemplate: LocalCLITemplate {
        didSet {
            UserDefaults.standard.set(selectedTemplate.rawValue, forKey: Self.selectedTemplateKey)
        }
    }

    var timeoutSeconds: Double {
        didSet {
            let clamped = max(5, timeoutSeconds)
            if clamped != timeoutSeconds {
                timeoutSeconds = clamped
                return
            }
            UserDefaults.standard.set(timeoutSeconds, forKey: Self.timeoutSecondsKey)
        }
    }

    var isConfigured: Bool {
        !commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        let savedTemplateRaw = UserDefaults.standard.string(forKey: Self.selectedTemplateKey) ?? ""
        selectedTemplate = LocalCLITemplate(rawValue: savedTemplateRaw) ?? .pi

        commandTemplate = UserDefaults.standard.string(forKey: Self.commandTemplateKey) ?? ""

        let savedTimeout = UserDefaults.standard.double(forKey: Self.timeoutSecondsKey)
        timeoutSeconds = savedTimeout > 0 ? savedTimeout : Self.defaultTimeoutSeconds
    }

    func loadTemplate(_ template: LocalCLITemplate) {
        selectedTemplate = template
        commandTemplate = template.commandTemplate
    }

    func enhance(systemPrompt: String, userPrompt: String) async throws -> String {
        guard isConfigured else {
            throw LocalCLIError.commandNotConfigured
        }

        let fullPrompt = Self.makeFullPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt)
        return try await executeCommand(
            commandTemplate: commandTemplate,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            fullPrompt: fullPrompt,
            timeout: timeoutSeconds
        )
    }

    static func makeFullPrompt(systemPrompt: String, userPrompt: String) -> String {
        """
        # System Message
        <SYSTEM_MESSAGE>
        \(systemPrompt)
        </SYSTEM_MESSAGE>

        # User Message Payload
        <USER_MESSAGE_PAYLOAD>
        \(userPrompt)
        </USER_MESSAGE_PAYLOAD>
        """
    }

    /// Runs the template through a login shell. Prompts travel in environment variables, and
    /// templates that do not reference them in arguments also receive the full prompt on stdin.
    /// Cancelling the calling task terminates the command and its children.
    private func executeCommand(
        commandTemplate: String,
        systemPrompt: String,
        userPrompt: String,
        fullPrompt: String,
        timeout: Double
    ) async throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = await ShellCommandEnvironment.resolvePreferredPATH(fallback: environment["PATH"])
        environment["VOCE_SYSTEM_PROMPT"] = systemPrompt
        environment["VOCE_USER_PROMPT"] = userPrompt
        environment["VOCE_FULL_PROMPT"] = fullPrompt

        let usesArgumentPrompt =
            commandTemplate == LocalCLITemplate.codex.commandTemplate
            || commandTemplate == LocalCLITemplate.claude.commandTemplate

        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", commandTemplate],
                environment: environment,
                standardInput: usesArgumentPrompt ? nil : Data(fullPrompt.utf8),
                timeout: timeout
            )
        } catch ProcessRunner.Failure.timedOut {
            throw LocalCLIError.timeout(seconds: timeout)
        } catch ProcessRunner.Failure.launchFailed(let message) {
            throw LocalCLIError.executionFailed(message)
        }

        let stdout = Self.cleanOutput(output.stdoutString)
        let stderr = Self.cleanOutput(output.stderrString)

        guard output.succeeded else {
            let status = Int(output.status)
            let looksLikeCommandNotFound = status == 127 || stderr.lowercased().contains("command not found")
            if looksLikeCommandNotFound {
                throw LocalCLIError.commandNotFound(stderr.isEmpty ? commandTemplate : stderr)
            }
            throw LocalCLIError.nonZeroExit(status: status, stderr: stderr)
        }

        // Pasting a cut-off enhancement would silently lose dictated text.
        guard !output.isStdoutTruncated else {
            throw LocalCLIError.outputIncomplete
        }

        guard !stdout.isEmpty else {
            throw LocalCLIError.emptyOutput
        }

        return stdout
    }

    private static func cleanOutput(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LocalCLIError: Error, LocalizedError {
    case commandNotConfigured
    case commandNotFound(String)
    case timeout(seconds: Double)
    case nonZeroExit(status: Int, stderr: String)
    case emptyOutput
    case outputIncomplete
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandNotConfigured:
            return String(localized: "Local CLI command is not configured. Load a template or enter a command first.")
        case .commandNotFound(let details):
            return String(
                format: String(
                    localized:
                        "Local CLI command was not found. Use an absolute path or fix your shell PATH. Details: %@"),
                details)
        case .timeout(let seconds):
            return String(format: String(localized: "Local CLI command timed out after %lld seconds."), Int64(seconds))
        case .nonZeroExit(let status, let stderr):
            if stderr.isEmpty {
                return String(format: String(localized: "Local CLI command failed with exit code %lld."), Int64(status))
            }
            return String(
                format: String(localized: "Local CLI command failed with exit code %lld: %@"), Int64(status), stderr)
        case .emptyOutput:
            return String(localized: "Local CLI command returned empty output.")
        case .outputIncomplete:
            return String(localized: "Local CLI command output was too large or did not finish.")
        case .executionFailed(let message):
            return String(format: String(localized: "Failed to execute Local CLI command: %@"), message)
        }
    }
}
