import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

final class ShortcutMonitor {
    #if VOCE_LOCAL
    // Internal Dock commands must not count as typing or interrupt a physical Fn hold.
    static let localDockEventTag: Int64 = 0x564F4345444F434B
    #endif
    fileprivate enum EventKind {
        case keyDown
        case keyUp
        case flagsChanged
        case mouseDown
        case mouseDragged
        case mouseUp
    }

    private struct ShortcutState {
        var shortcut: Shortcut
        var isDown = false
        var pressedAt: TimeInterval?
        var isInterrupted = false
        var requiresStandaloneRelease = false
    }

    private var shortcuts: [ShortcutAction: ShortcutState] = [:]
    private var pressedKeyCodes = Set<UInt16>()
    private var suppressedMouseButtons = Set<UInt16>()
    private var interruptibleActions: Set<ShortcutAction> = []
    private var standaloneModifierActions: Set<ShortcutAction> = []
    private var onShortcutDown: ((ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutUp: ((ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)?
    private var onStandaloneModifierChord: ((ShortcutAction) -> Void)?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var hasLoggedTapFailure = false
    private var lastFnReleaseTime: TimeInterval?
    private var awaitingGlobeTapKeyUp = false
    private let logger = Logger(subsystem: "ro.andrei.Voce", category: "ShortcutMonitor")

    private static let shortcutInterruptionWindow: TimeInterval = 1.0

    var isRunning: Bool {
        guard let eventTap, let eventTapRunLoopSource else { return false }
        return CFMachPortIsValid(eventTap) && CFRunLoopSourceIsValid(eventTapRunLoopSource)
    }

    deinit {
        stop()
    }

    @discardableResult
    func start(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        standaloneModifierActions: Set<ShortcutAction> = [],
        onShortcutDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutUp: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)? = nil,
        onStandaloneModifierChord: ((ShortcutAction) -> Void)? = nil
    ) -> Bool {
        stop()

        for (action, shortcut) in shortcuts {
            self.shortcuts[action] = ShortcutState(shortcut: shortcut)
        }

        guard !self.shortcuts.isEmpty else {
            return true
        }

        self.interruptibleActions = interruptibleActions
        self.standaloneModifierActions = standaloneModifierActions
        self.onShortcutDown = onShortcutDown
        self.onShortcutUp = onShortcutUp
        self.onShortcutInterrupted = onShortcutInterrupted
        self.onStandaloneModifierChord = onStandaloneModifierChord

        return installEventTap()
    }

    func updateStandaloneModifierActions(_ actions: Set<ShortcutAction>) {
        standaloneModifierActions = actions
    }

    func stop() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        shortcuts = [:]
        pressedKeyCodes = []
        lastFnReleaseTime = nil
        awaitingGlobeTapKeyUp = false
        suppressedMouseButtons = []
        interruptibleActions = []
        standaloneModifierActions = []
        onShortcutDown = nil
        onShortcutUp = nil
        onShortcutInterrupted = nil
        onStandaloneModifierChord = nil
    }

    private func installEventTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.logger.notice("Global shortcut event tap disabled type=\(type.rawValue, privacy: .public); re-enabling")
                monitor.resetPressedShortcutsAfterTapInterruption()
                if let eventTap = monitor.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let shouldSuppress = monitor.handleCGEvent(type: type, event: event)
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.eventMask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            if !hasLoggedTapFailure {
                logger.error("Failed to install global shortcut event tap accessibility=\(AXIsProcessTrusted(), privacy: .public)")
                hasLoggedTapFailure = true
            }
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            logger.error("Failed to create global shortcut event tap run loop source")
            return false
        }

        self.eventTap = eventTap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        hasLoggedTapFailure = false
        logger.notice("Installed global shortcut event tap shortcuts=\(self.shortcuts.count, privacy: .public) accessibility=\(AXIsProcessTrusted(), privacy: .public)")
        return true
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        #if VOCE_LOCAL
        if event.getIntegerValueField(.eventSourceUserData) == Self.localDockEventTag,
            event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
        {
            return false
        }
        #endif
        guard let eventKind = EventKind(type) else {
            return false
        }

        let inputCode: UInt16
        switch eventKind {
        case .keyDown, .keyUp, .flagsChanged:
            inputCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        case .mouseDown, .mouseDragged, .mouseUp:
            inputCode = UInt16(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
        }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let allowsShortcutHandling = UserSessionInputPolicy.allowsShortcutHandling
        if eventKind == .flagsChanged,
            inputCode == UInt16(kVK_Function) || modifierFlags.contains(.function)
        {
            logger.notice("Fn modifier event keyCode=\(inputCode, privacy: .public) flags=\(event.flags.rawValue, privacy: .public) sessionAllowsInput=\(allowsShortcutHandling, privacy: .public)")
        }
        guard allowsShortcutHandling else {
            clearPressedShortcutState()
            return false
        }
        if inputCode == 179, eventKind == .keyDown || eventKind == .keyUp {
            logger.notice("Globe companion event type=\(type.rawValue, privacy: .public) sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID), privacy: .public)")
        }
        return handleEvent(
            kind: eventKind,
            inputCode: inputCode,
            modifierFlags: modifierFlags,
            eventTime: ProcessInfo.processInfo.systemUptime
        )
    }

    private func resetPressedShortcutsAfterTapInterruption() {
        releasePressedShortcuts(eventTime: ProcessInfo.processInfo.systemUptime)
    }

    private func clearPressedShortcutState() {
        releasePressedShortcuts(eventTime: ProcessInfo.processInfo.systemUptime)
        suppressedMouseButtons.removeAll()
    }

    private func releasePressedShortcuts(eventTime: TimeInterval) {
        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action] else { continue }
            let shouldDispatchUp = state.isDown && !state.requiresStandaloneRelease
            state.isDown = false
            state.pressedAt = nil
            state.isInterrupted = false
            state.requiresStandaloneRelease = false
            shortcuts[action] = state
            if shouldDispatchUp {
                dispatchShortcutUp(for: action, eventTime: eventTime)
            }
        }
        pressedKeyCodes.removeAll()
    }

    private func handleEvent(
        kind: EventKind,
        inputCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) -> Bool {
        // This Mac sends a Globe tap (179) immediately after the Fn modifier release.
        // It belongs to that same tap, rather than a key chord that cancels double Fn.
        if inputCode == 179 {
            if kind == .keyDown {
                awaitingGlobeTapKeyUp = lastFnReleaseTime.map {
                    eventTime >= $0 && eventTime - $0 < 0.02
                } ?? false
                if awaitingGlobeTapKeyUp {
                    logger.debug("Ignoring companion Globe tap after Fn release")
                    return false
                }
            } else if kind == .keyUp, awaitingGlobeTapKeyUp {
                awaitingGlobeTapKeyUp = false
                return false
            }
        }
        var shouldSuppress: Bool
        switch kind {
        case .mouseDragged:
            shouldSuppress = suppressedMouseButtons.contains(inputCode)
        case .mouseUp:
            shouldSuppress = suppressedMouseButtons.remove(inputCode) != nil
        case .keyDown, .keyUp, .flagsChanged, .mouseDown:
            shouldSuppress = false
        }

        updatePressedKeyCodes(kind: kind, inputCode: inputCode)
        invalidateStandaloneModifierCandidateForKeyboardEvent(
            kind: kind,
            inputCode: inputCode,
            modifierFlags: modifierFlags,
            eventTime: eventTime
        )

        if kind == .keyDown {
            handleShortcutInterruptions(keyCode: inputCode, eventTime: eventTime)
        }

        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action] else {
                continue
            }

            if state.shortcut.isModifierOnly {
                handleModifierOnlyShortcut(
                    action: action,
                    state: state,
                    kind: kind,
                    keyCode: inputCode,
                    modifierFlags: modifierFlags,
                    eventTime: eventTime
                )
                continue
            }

            let transition: ShortcutTransition
            switch state.shortcut.kind {
            case .key:
                transition = transitionForKeyShortcut(
                    state.shortcut,
                    isDown: state.isDown,
                    kind: kind,
                    keyCode: inputCode,
                    modifierFlags: modifierFlags
                )
            case .mouseButton:
                transition = transitionForMouseShortcut(
                    state.shortcut,
                    isDown: state.isDown,
                    kind: kind,
                    buttonNumber: inputCode,
                    modifierFlags: modifierFlags
                )
            case .modifierOnly:
                transition = .none
            }

            switch transition {
            case .none:
                break
            case .suppress:
                if kind != .flagsChanged {
                    shouldSuppress = true
                }
            case .keyDown:
                state.isDown = true
                state.pressedAt = eventTime
                state.isInterrupted = false
                shortcuts[action] = state
                if state.shortcut.kind == .mouseButton {
                    suppressedMouseButtons.insert(inputCode)
                }
                shouldSuppress = true
                dispatchShortcutDown(for: action, eventTime: eventTime)
            case .keyUp:
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                if kind != .flagsChanged {
                    shouldSuppress = true
                }
                dispatchShortcutUp(for: action, eventTime: eventTime)
            }
        }

        return shouldSuppress
    }

    private enum ShortcutTransition {
        case none
        case suppress
        case keyDown
        case keyUp
    }

    private func transitionForKeyShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .keyDown:
            guard shortcut.matchesKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .keyUp:
            return isDown && keyCode == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(
                modifierFlags,
                forKeyCode: shortcut.keyCode
            )
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        case .mouseDown, .mouseDragged, .mouseUp:
            return .none
        }
    }

    private func transitionForMouseShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        buttonNumber: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .mouseDown:
            guard shortcut.matchesMouseEvent(
                buttonNumber: buttonNumber,
                modifierFlags: modifierFlags
            ) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .mouseUp:
            return isDown && buttonNumber == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: nil)
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        case .keyDown, .keyUp, .mouseDragged:
            return .none
        }
    }

    private func handleModifierOnlyShortcut(
        action: ShortcutAction,
        state: ShortcutState,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) {
        var state = state

        guard kind == .flagsChanged else {
            return
        }

        if state.isDown {
            if state.shortcut.shouldReleaseModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
                if keyCode == UInt16(kVK_Function) {
                    lastFnReleaseTime = eventTime
                }
                let shouldTrigger =
                    state.requiresStandaloneRelease
                    && !state.isInterrupted
                let shouldDispatchUp = !state.requiresStandaloneRelease
                let pressedAt = state.pressedAt
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                state.requiresStandaloneRelease = false
                shortcuts[action] = state
                if shouldTrigger, let pressedAt {
                    dispatchShortcutDown(for: action, eventTime: pressedAt)
                    dispatchShortcutUp(for: action, eventTime: eventTime)
                } else if shouldDispatchUp {
                    dispatchShortcutUp(for: action, eventTime: eventTime)
                }
            }

            return
        }

        if state.shortcut.matchesModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
            state.isDown = true
            state.pressedAt = eventTime
            state.requiresStandaloneRelease = standaloneModifierActions.contains(action)
            state.isInterrupted = state.requiresStandaloneRelease && !pressedKeyCodes.isEmpty
            #if VOCE_LOCAL
            if action == .primaryRecording {
                state.isInterrupted = !pressedKeyCodes.isEmpty
            }
            #endif
            shortcuts[action] = state
            if !state.requiresStandaloneRelease && !state.isInterrupted {
                dispatchShortcutDown(for: action, eventTime: eventTime)
            }
        }
    }

    private func updatePressedKeyCodes(kind: EventKind, inputCode: UInt16) {
        switch kind {
        case .keyDown:
            pressedKeyCodes.insert(inputCode)
        case .keyUp:
            pressedKeyCodes.remove(inputCode)
        case .flagsChanged, .mouseDown, .mouseDragged, .mouseUp:
            break
        }
    }

    private func invalidateStandaloneModifierCandidateForKeyboardEvent(
        kind: EventKind,
        inputCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) {
        guard kind == .keyDown || kind == .keyUp || kind == .flagsChanged else {
            return
        }

        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action],
                state.isDown,
                !state.isInterrupted
            else {
                continue
            }

            let isReleaseEvent = kind == .flagsChanged
                && state.shortcut.shouldReleaseModifierEvent(
                    keyCode: inputCode,
                    modifierFlags: modifierFlags
                )
            #if VOCE_LOCAL
            // A held Fn is delivered immediately so push-to-talk can start before release.
            // Chords must cancel it even after the normal interruption window has elapsed.
            if action == .primaryRecording, state.shortcut.isModifierOnly {
                let isRepeatedPress = kind == .flagsChanged
                    && state.shortcut.matchesModifierEvent(keyCode: inputCode, modifierFlags: modifierFlags)
                if !isReleaseEvent && !isRepeatedPress {
                    state.isInterrupted = true
                    shortcuts[action] = state
                    dispatchShortcutInterrupted(for: action, eventTime: eventTime)
                }
                continue
            }
            #endif
            guard state.requiresStandaloneRelease else { continue }
            if !isReleaseEvent {
                state.isInterrupted = true
                shortcuts[action] = state
            }
        }
    }

    private func handleShortcutInterruptions(keyCode: UInt16, eventTime: TimeInterval) {
        guard !Shortcut.isModifierKeyCode(keyCode) else {
            return
        }

        for action in standaloneModifierActions {
            guard shortcuts[action]?.shortcut.isModifierOnly == true else { continue }
            onStandaloneModifierChord?(action)
        }
        #if VOCE_LOCAL
        if !standaloneModifierActions.contains(.primaryRecording),
            shortcuts[.primaryRecording]?.shortcut.isModifierOnly == true
        {
            onStandaloneModifierChord?(.primaryRecording)
        }
        #endif

        for action in interruptibleActions {
            guard var state = shortcuts[action],
                state.isDown,
                !state.isInterrupted,
                let pressedAt = state.pressedAt,
                eventTime - pressedAt <= Self.shortcutInterruptionWindow,
                state.shortcut.isInterruptedByAdditionalKeyDown(keyCode: keyCode)
            else {
                continue
            }

            state.isInterrupted = true
            shortcuts[action] = state
            dispatchShortcutInterrupted(for: action, eventTime: eventTime)
        }
    }

    private func dispatchShortcutDown(for action: ShortcutAction, eventTime: TimeInterval) {
        logger.debug("Matched shortcut down action=\(action.storageName, privacy: .public)")
        DispatchQueue.main.async { [onShortcutDown] in
            onShortcutDown?(action, eventTime)
        }
    }

    private func dispatchShortcutUp(for action: ShortcutAction, eventTime: TimeInterval) {
        logger.debug("Matched shortcut up action=\(action.storageName, privacy: .public)")
        DispatchQueue.main.async { [onShortcutUp] in
            onShortcutUp?(action, eventTime)
        }
    }

    private func dispatchShortcutInterrupted(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onShortcutInterrupted] in
            onShortcutInterrupted?(action, eventTime)
        }
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.keyUp,
        CGEventType.flagsChanged,
        CGEventType.otherMouseDown,
        CGEventType.otherMouseDragged,
        CGEventType.otherMouseUp,
    ].reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << Int(type.rawValue))
    }
}

private extension ShortcutMonitor.EventKind {
    init?(_ type: CGEventType) {
        switch type {
        case .keyDown:
            self = .keyDown
        case .keyUp:
            self = .keyUp
        case .flagsChanged:
            self = .flagsChanged
        case .otherMouseDown:
            self = .mouseDown
        case .otherMouseDragged:
            self = .mouseDragged
        case .otherMouseUp:
            self = .mouseUp
        default:
            return nil
        }
    }
}
