import AppKit
import Foundation
import os

enum BrowserType {
    case safari
    case arc
    case dia
    case chrome
    case comet
    case edge
    case brave
    case opera
    case vivaldi
    case orion
    case yandex

    var scriptName: String {
        switch self {
        case .safari: return "safariURL"
        case .arc: return "arcURL"
        case .dia: return "diaURL"
        case .chrome: return "chromeURL"
        case .comet: return "cometURL"
        case .edge: return "edgeURL"
        case .brave: return "braveURL"
        case .opera: return "operaURL"
        case .vivaldi: return "vivaldiURL"
        case .orion: return "orionURL"
        case .yandex: return "yandexURL"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .arc: return "company.thebrowser.Browser"
        case .dia: return "company.thebrowser.dia"
        case .chrome: return "com.google.Chrome"
        case .comet: return "ai.perplexity.comet"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .opera: return "com.operasoftware.Opera"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .orion: return "com.kagi.kagimacOS"
        case .yandex: return "ru.yandex.desktop.yandex-browser"
        }
    }

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .arc: return "Arc"
        case .dia: return "Dia"
        case .chrome: return "Google Chrome"
        case .comet: return "Comet"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .opera: return "Opera"
        case .vivaldi: return "Vivaldi"
        case .orion: return "Orion"
        case .yandex: return "Yandex Browser"
        }
    }

    static var allCases: [BrowserType] {
        [.safari, .arc, .dia, .chrome, .comet, .edge, .brave, .opera, .vivaldi, .orion, .yandex]
    }

    static var installedBrowsers: [BrowserType] {
        allCases.filter { browser in
            let workspace = NSWorkspace.shared
            return workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil
        }
    }
}

enum BrowserURLError: Error {
    case scriptNotFound
    case executionFailed
    case executionTimedOut
    case browserNotRunning
    case noActiveWindow
    case noActiveTab
}

class BrowserURLService {
    static let shared = BrowserURLService()

    private let logger = Logger(
        subsystem: "ro.andrei.Voce",
        category: "browser.applescript"
    )
    private let scriptTimeout: TimeInterval = 1.5

    private init() {}

    func getCurrentURL(from browser: BrowserType) async throws -> String {
        guard let scriptURL = Bundle.main.url(forResource: browser.scriptName, withExtension: "scpt") else {
            logger.error("❌ AppleScript file not found: \(browser.scriptName, privacy: .public).scpt")
            throw BrowserURLError.scriptNotFound
        }

        logger.debug("🔍 Attempting to execute AppleScript for \(browser.displayName, privacy: .public)")

        // Check if browser is running
        if !isRunning(browser) {
            logger.error("❌ Browser not running: \(browser.displayName, privacy: .public)")
            throw BrowserURLError.browserNotRunning
        }

        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: [scriptURL.path],
                timeout: scriptTimeout,
                outputLimit: 64 * 1024,
                terminationGracePeriod: 0.5
            )
        } catch ProcessRunner.Failure.timedOut {
            logger.error("❌ AppleScript timed out for \(browser.displayName, privacy: .public)")
            throw BrowserURLError.executionTimedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error(
                "❌ AppleScript execution failed for \(browser.displayName, privacy: .public): \(error, privacy: .public)"
            )
            throw BrowserURLError.executionFailed
        }

        // osascript reports script errors, such as a missing window, on stderr with a nonzero status.
        guard output.succeeded else {
            logger.error(
                "❌ AppleScript error for \(browser.displayName, privacy: .public) status=\(output.status, privacy: .public): \(output.stderrString, privacy: .private)"
            )
            throw BrowserURLError.executionFailed
        }

        let url = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            logger.error("❌ Empty output from AppleScript for \(browser.displayName, privacy: .public)")
            throw BrowserURLError.noActiveTab
        }

        logger.debug("✅ Retrieved URL from \(browser.displayName, privacy: .public): \(url, privacy: .private)")
        return url
    }

    func isRunning(_ browser: BrowserType) -> Bool {
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications
        let isRunning = runningApps.contains { $0.bundleIdentifier == browser.bundleIdentifier }
        logger.debug("\(browser.displayName, privacy: .public) running status: \(isRunning, privacy: .public)")
        return isRunning
    }
}
