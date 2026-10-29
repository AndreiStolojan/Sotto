import AppKit
import Carbon
import Foundation
import os

class CursorPaster {
    private typealias ClipboardItemSnapshot = [(NSPasteboard.PasteboardType, Data)]
    private typealias ClipboardSnapshot = [ClipboardItemSnapshot]
    private static let logger = Logger(subsystem: "ro.andrei.Voce", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted

        var didPostPasteCommand: Bool {
            self == .commandPosted
        }
    }

    struct PasteOutcome {
        let result: PasteResult
        let autoLearnGeneration: UInt64?
    }

    private static let prePasteDelay: TimeInterval = 0.10
    private static let pasteShortcutEventDelay: TimeInterval = 0.01

    /// The latest paste session. Each new session waits for it, so one session's
    /// Command-V can never paste text that a later session put on the clipboard.
    @MainActor private static var latestPasteSession: Task<PasteOutcome, Never>?

    /// The clipboard contents to put back once the most recent session's restore
    /// delay ends. A session that starts before then inherits these contents
    /// instead of snapshotting the previous session's transcription.
    @MainActor private static var pendingRestore: (sessionID: String, contents: ClipboardSnapshot)?

    static func pasteAtCursor(_ text: String) {
        Task {
            let pasteTask = await MainActor.run {
                startPasteAtCursor(text)
            }
            _ = await pasteTask.value
        }
    }

    @MainActor
    @discardableResult
    static func startPasteAtCursor(_ text: String) -> Task<PasteOutcome, Never> {
        let previousSession = latestPasteSession
        let session = Task { @MainActor in
            _ = await previousSession?.value
            return await performPasteSession(text)
        }
        latestPasteSession = session
        return session
    }

    @MainActor
    private static func performPasteSession(_ text: String) async -> PasteOutcome {
        let pasteboard = NSPasteboard.general
        let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")
        let savedContents = shouldRestoreClipboard ? contentsToRestore(from: pasteboard) : []
        let sessionID = UUID().uuidString

        guard
            ClipboardManager.setClipboard(
                text,
                transient: shouldRestoreClipboard,
                sessionID: shouldRestoreClipboard ? sessionID : nil
            )
        else {
            logger.error("Failed to prepare clipboard for paste")
            if shouldRestoreClipboard {
                pendingRestore = nil
                pasteboard.clearContents()
                if !savedContents.isEmpty {
                    pasteboard.writeObjects(pasteboardItems(from: savedContents))
                }
            }
            return PasteOutcome(result: .commandNotPosted, autoLearnGeneration: nil)
        }

        if shouldRestoreClipboard {
            pendingRestore = (sessionID, savedContents)
        }

        await wait(prePasteDelay)

        let pasteResult: PasteResult
        let autoLearnGeneration: UInt64?
        if AutoLearnSettings.isEnabled {
            let targetProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            pasteResult = await postPasteCommand()
            autoLearnGeneration = await AutoLearnService.shared.pasteDidFinish(
                text: text,
                processID: targetProcessID,
                commandPosted: pasteResult.didPostPasteCommand
            )
        } else {
            pasteResult = await postPasteCommand()
            autoLearnGeneration = nil
        }
        if shouldRestoreClipboard {
            scheduleClipboardRestore(expectedText: text, sessionID: sessionID, on: pasteboard)
        }

        return PasteOutcome(result: pasteResult, autoLearnGeneration: autoLearnGeneration)
    }

    /// Reads the user's clipboard for context, excluding Sotto's temporary paste payload.
    @MainActor
    static func clipboardContextText() -> String? {
        let pasteboard = NSPasteboard.general
        if let pendingRestore,
            pasteboard.string(forType: ClipboardManager.pasteSessionType) == pendingRestore.sessionID
        {
            return pasteboardItems(from: pendingRestore.contents).lazy.compactMap { $0.string(forType: .string) }.first
        }
        return pasteboard.string(forType: .string)
    }

    /// Returns the user's clipboard contents. While an earlier session still owns
    /// the pasteboard, those are the contents that session saved, not its text.
    @MainActor
    private static func contentsToRestore(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        if let pendingRestore,
            pasteboard.string(forType: ClipboardManager.pasteSessionType) == pendingRestore.sessionID
        {
            return pendingRestore.contents
        }
        return snapshotClipboard(from: pasteboard)
    }

    private static func snapshotClipboard(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                if let data = item.data(forType: type) {
                    return (type, data)
                }
                return nil
            }
        }
    }

    @MainActor
    private static func postPasteCommand() async -> PasteResult {
        if PasteMethod.current() == .appleScript {
            return pasteUsingAppleScript() ? .commandPosted : .commandNotPosted
        } else {
            return await pasteFromClipboard()
        }
    }

    @MainActor
    private static func scheduleClipboardRestore(
        expectedText: String,
        sessionID: String,
        on pasteboard: NSPasteboard
    ) {
        let delay = SettingsValueLimits.clamped(
            UserDefaults.standard.double(forKey: "clipboardRestoreDelay"),
            to: SettingsValueLimits.clipboardRestoreDelay
        )

        Task { @MainActor in
            await wait(delay)
            // A newer session has taken over the saved contents and restores them itself.
            guard let pendingRestore, pendingRestore.sessionID == sessionID else { return }
            Self.pendingRestore = nil
            guard pasteboardStillOwnedByPasteSession(pasteboard, expectedText: expectedText, sessionID: sessionID)
            else {
                return
            }
            let savedContents = pendingRestore.contents
            pasteboard.clearContents()
            if !savedContents.isEmpty {
                pasteboard.writeObjects(pasteboardItems(from: savedContents))
            }
        }
    }

    private static func pasteboardStillOwnedByPasteSession(
        _ pasteboard: NSPasteboard,
        expectedText: String,
        sessionID: String
    ) -> Bool {
        pasteboard.string(forType: .string) == expectedText
            && pasteboard.string(forType: ClipboardManager.pasteSessionType) == sessionID
    }

    private static func pasteboardItems(from snapshot: ClipboardSnapshot) -> [NSPasteboardItem] {
        snapshot.map { itemSnapshot in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
        }
    }

    // MARK: - AppleScript paste

    // "X – QWERTY ⌘" layouts remap to QWERTY when Command is held, so keystroke "v" resolves
    // the wrong key code. key code 9 (physical V) bypasses layout translation for those layouts.
    private static func makeScript(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    private static let pasteScriptKeystroke = makeScript(
        "tell application \"System Events\" to keystroke \"v\" using command down")
    private static let pasteScriptKeyCode = makeScript(
        "tell application \"System Events\" to key code 9 using command down")

    @MainActor
    private static var layoutSwitchesToQWERTYOnCommand: Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return false }
        return (Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String).hasSuffix("⌘")
    }

    @MainActor
    private static func pasteUsingAppleScript() -> Bool {
        guard let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke else {
            logger.error("AppleScript paste script is unavailable")
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript paste failed: \(String(describing: error), privacy: .public)")
        }
        return error == nil
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    @MainActor
    private static func pasteFromClipboard() async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else {
            logger.error("Failed to create Cmd+V keyboard events")
            return .commandNotPosted
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        cmdUp.post(tap: .cghidEventTap)

        return .commandPosted
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds.isFinite, seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Send Key

    static func performSendKey(_ key: FinishAndSendKey) {
        guard key.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)

        switch key {
        case .none: return
        case .enter: break
        case .shiftEnter:
            enterDown?.flags = .maskShift
            enterUp?.flags = .maskShift
        case .commandEnter:
            enterDown?.flags = .maskCommand
            enterUp?.flags = .maskCommand
        }

        enterDown?.post(tap: .cghidEventTap)
        enterUp?.post(tap: .cghidEventTap)
    }
}
