import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import os

@MainActor
class RecordingShortcutManager: ObservableObject {
    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            if secondaryRecordingShortcut == .none {
                ShortcutStore.setShortcut(nil, for: .secondaryRecording)
            }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            primaryRecordingShortcutModeSource.primaryMode = primaryRecordingShortcutMode
            shortcutModeHandler.resetShortcutState(for: .primaryRecording)
            modeShortcutManager.recordingModeDidChange()
            updateStandaloneModifierActions()
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
            shortcutModeHandler.resetShortcutState(for: .secondaryRecording)
            updateStandaloneModifierActions()
        }
    }
    private var engine: VoceEngine
    private var recorderUIManager: RecorderUIManager
    private var recorderPanelShortcutManager: RecorderPanelShortcutManager
    private let modeShortcutManager: ModeShortcutManager
    private let shortcutMonitor = ShortcutMonitor()
    private var shortcutMonitorGeneration = UUID()
    private var shortcutChangeObserver: NSObjectProtocol?
    private var lifecycleCancellable: AnyCancellable?
    private var shortcutMonitoringRetryTask: Task<Void, Never>?
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let primaryRecordingShortcutModeSource: RecordingShortcutModeSource
    private let logger = Logger(subsystem: "ro.andrei.Voce", category: "RecordingShortcutManager")

    enum Mode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"
        case doubleTap = "doubleTap"

        var displayName: String {
            switch self {
            case .toggle: return String(localized: "Toggle")
            case .pushToTalk: return String(localized: "Push to Talk")
            case .hybrid: return String(localized: "Hybrid")
            case .doubleTap: return String(localized: "Double Tap")
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none = "none"
        case custom = "custom"

        var displayName: String {
            switch self {
            case .none: return String(localized: "None")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    private static func canHandleShortcutAction(for recordingState: RecordingState) -> Bool {
        recordingState != .transcribing && recordingState != .enhancing && recordingState != .busy
    }

    init(engine: VoceEngine, recorderUIManager: RecorderUIManager) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()

        self.primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .primaryRecording,
            allowsNone: false
        )
        self.secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .secondaryRecording,
            allowsNone: true
        )

        let primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .primaryRecording
        )
        self.primaryRecordingShortcutMode = primaryRecordingShortcutMode
        self.secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .secondaryRecording
        )

        let shortcutModeHandler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                Self.canHandleShortcutAction(for: engine.recordingState)
            },
            isRecorderVisible: {
                recorderUIManager.isRecorderPanelVisible
            },
            recordingState: {
                engine.recordingState
            },
            toggleRecorderPanel: { modeId in
                await recorderUIManager.toggleRecorderPanel(modeId: modeId)
            },
            cancelRecording: {
                await recorderUIManager.cancelRecording()
            }
        )

        let primaryRecordingShortcutModeSource = RecordingShortcutModeSource(
            primaryMode: primaryRecordingShortcutMode
        )

        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.recorderPanelShortcutManager = RecorderPanelShortcutManager(recorderUIManager: recorderUIManager)
        self.shortcutModeHandler = shortcutModeHandler
        self.primaryRecordingShortcutModeSource = primaryRecordingShortcutModeSource
        self.modeShortcutManager = ModeShortcutManager(
            modeProvider: {
                primaryRecordingShortcutModeSource.primaryMode
            },
            shortcutModeHandler: shortcutModeHandler
        )

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShortcutMonitoring()
            }
        }

        lifecycleCancellable = LifecycleObserver.shared.publisher(
            for: [.applicationDidBecomeActive, .systemDidWake]
        ).sink { [weak self] _ in
            Task { @MainActor in
                self?.retryShortcutMonitoringIfNeeded()
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.refreshShortcutMonitoring()
        }
    }

    /// Retries a failed event tap after permission changes without resetting active shortcuts.
    private func retryShortcutMonitoringIfNeeded() {
        guard AXIsProcessTrusted(), !shortcutMonitor.isRunning else { return }
        refreshShortcutMonitoring()
    }

    /// Handles Accessibility grants made while the app remains in the background.
    private func scheduleShortcutMonitoringRetry() {
        guard shortcutMonitoringRetryTask == nil else { return }
        shortcutMonitoringRetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                self.retryShortcutMonitoringIfNeeded()
            }
        }
    }

    private func refreshShortcutMonitoring() {
        removeAllMonitoring()

        refreshShortcutMonitor()
    }

    private func refreshShortcutMonitor() {
        let callbackLogger = logger
        let generation = shortcutMonitorGeneration
        #if VOCE_LOCAL
            let primaryShortcut: Shortcut? = .modifierOnly(
                keyCode: UInt16(kVK_Function),
                modifierFlags: [.function]
            )
            let secondaryShortcut: Shortcut? = nil
            var shortcuts: [ShortcutAction: Shortcut] = [:]
        #else
        let primaryShortcut = primaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil
        let secondaryShortcut =
            secondaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        #endif
        var interruptibleRecordingActions = Set<ShortcutAction>()

        if let primaryShortcut {
            shortcuts[.primaryRecording] = primaryShortcut
            interruptibleRecordingActions.insert(.primaryRecording)
        }

        if let secondaryShortcut {
            shortcuts[.secondaryRecording] = secondaryShortcut
            interruptibleRecordingActions.insert(.secondaryRecording)
        }

        let didStart = shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleRecordingActions,
            standaloneModifierActions: standaloneModifierActions,
            onShortcutDown: { [weak self, callbackLogger] action, eventTime in
                Task { @MainActor in
                    guard let self else {
                        callbackLogger.error("Shortcut down callback lost its recording manager")
                        return
                    }
                    guard self.shortcutMonitorGeneration == generation else { return }
                    guard let mode = self.recordingMode(for: action) else { return }
                    self.logger.notice("Received shortcut down action=\(action.storageName, privacy: .public) mode=\(mode.rawValue, privacy: .public) state=\(String(describing: self.engine.recordingState), privacy: .public) panelVisible=\(self.recorderUIManager.isRecorderPanelVisible, privacy: .public)")
                    await self.shortcutModeHandler.handleShortcutDown(
                        action: action,
                        eventTime: eventTime,
                        mode: mode
                    )
                }
            },
            onShortcutUp: { [weak self, callbackLogger] action, eventTime in
                Task { @MainActor in
                    guard let self else {
                        callbackLogger.error("Shortcut up callback lost its recording manager")
                        return
                    }
                    guard self.shortcutMonitorGeneration == generation else { return }
                    if let mode = self.recordingMode(for: action) {
                        self.logger.notice("Received shortcut up action=\(action.storageName, privacy: .public) mode=\(mode.rawValue, privacy: .public) state=\(String(describing: self.engine.recordingState), privacy: .public) panelVisible=\(self.recorderUIManager.isRecorderPanelVisible, privacy: .public)")
                        await self.shortcutModeHandler.handleShortcutUp(
                            action: action,
                            eventTime: eventTime,
                            mode: mode
                        )
                    } else {
                        await self.handleGlobalShortcut(action)
                    }
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                Task { @MainActor in
                    guard let self, self.shortcutMonitorGeneration == generation, self.recordingMode(for: action) != nil else { return }
                    await self.shortcutModeHandler.handleInterruption(action: action)
                }
            },
            onStandaloneModifierChord: { [weak self] action in
                MainActor.assumeIsolated {
                    guard let self, self.shortcutMonitorGeneration == generation else { return }
                    self.shortcutModeHandler.clearPendingDoubleTap(for: action)
                }
            }
        )
        if didStart {
            shortcutMonitoringRetryTask?.cancel()
            shortcutMonitoringRetryTask = nil
        } else {
            scheduleShortcutMonitoringRetry()
        }
    }

    private var standaloneModifierActions: Set<ShortcutAction> {
        #if VOCE_LOCAL
            return []
        #else
        var actions = Set<ShortcutAction>()
        if primaryRecordingShortcutMode == .toggle || primaryRecordingShortcutMode == .doubleTap {
            actions.insert(.primaryRecording)
        }
        if secondaryRecordingShortcutMode == .toggle || secondaryRecordingShortcutMode == .doubleTap {
            actions.insert(.secondaryRecording)
        }
        return actions
        #endif
    }

    private func updateStandaloneModifierActions() {
        shortcutMonitor.updateStandaloneModifierActions(standaloneModifierActions)
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording:
            #if VOCE_LOCAL
                return .doubleTap
            #else
            return primaryRecordingShortcutMode
            #endif
        case .secondaryRecording:
            return secondaryRecordingShortcutMode
        default:
            return nil
        }
    }

    private func handleGlobalShortcut(_ action: ShortcutAction) async {
        switch action {
        case .pasteLastTranscription:
            LastTranscriptionService.pasteLastTranscription(from: engine.modelContext)
        case .pasteLastEnhancement:
            LastTranscriptionService.pasteLastEnhancement(from: engine.modelContext)
        case .retryLastTranscription:
            LastTranscriptionService.retryLastTranscription(
                from: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                serviceRegistry: engine.serviceRegistry,
                enhancementService: engine.enhancementService
            )
        case .openQuickHistory:
            QuickHistoryController.shared.show(modelContext: engine.modelContext, engine: engine)
        case .quickAddToDictionary:
            DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
        default:
            break
        }
    }

    private func removeAllMonitoring() {
        shortcutMonitorGeneration = UUID()
        shortcutMonitor.stop()

        shortcutModeHandler.reset()
    }

    var isShortcutConfigured: Bool {
        let isPrimaryShortcutConfigured =
            primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
        let isSecondaryShortcutConfigured =
            secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil
        return isPrimaryShortcutConfigured && isSecondaryShortcutConfigured
    }

    func updateShortcutStatus() {
        // Called when a shortcut changes
        refreshShortcutMonitoring()
    }

    deinit {
        shortcutMonitoringRetryTask?.cancel()
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        MainActor.assumeIsolated {
            removeAllMonitoring()
        }
    }
}

@MainActor
private final class RecordingShortcutModeSource {
    var primaryMode: RecordingShortcutManager.Mode

    init(primaryMode: RecordingShortcutManager.Mode) {
        self.primaryMode = primaryMode
    }
}

@MainActor
final class RecordingShortcutModeHandler {
    private let logger = Logger(subsystem: "ro.andrei.Voce", category: "RecordingShortcutModeHandler")
    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let toggleRecorderPanel: @MainActor (UUID?) async -> Void
    private let cancelRecording: @MainActor () async -> Void

    private var shortcutPressStartTime: TimeInterval?
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?
    private var interruptedRecordingActions = Set<ShortcutAction>()
    private var activeShortcutCanCancelAccidentalStart = false
    private var activeShortcutIsDoubleTap = false
    private var lastShortcutPressTime: Date?
    private var pendingDoubleTapReleaseTimes: [ShortcutAction: TimeInterval] = [:]

    #if VOCE_LOCAL
    private enum FnRecordingKind { case held, handsFree }
    private var fnRecordingKind: FnRecordingKind?
    private var fnPressTime: TimeInterval?
    private var fnLastEventTime: TimeInterval = -.infinity
    private var fnFirstRelease: TimeInterval?
    private var fnInterrupted = false
    private var fnHoldTask: Task<Void, Never>?
    private var fnHoldToken: UUID?
    private var fnStarting = false
    private var fnStopRequested = false
    private var fnCancelRequested = false
    private var fnStopping = false
    private var fnLastStopTime: Date?
    #endif

    private let shortcutPressCooldown: TimeInterval = 0.5
    private let hybridPressThreshold: TimeInterval = 0.5
    private let doubleTapThreshold: TimeInterval = 0.7

    init(
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        toggleRecorderPanel: @escaping @MainActor (UUID?) async -> Void,
        cancelRecording: @escaping @MainActor () async -> Void
    ) {
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.toggleRecorderPanel = toggleRecorderPanel
        self.cancelRecording = cancelRecording
    }

    func reset() {
        #if VOCE_LOCAL
        resetLocalFnState()
        #endif
        logger.notice("Resetting recording shortcut handler")
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        clearPendingDoubleTaps()
    }

    func clearPendingDoubleTaps() {
        pendingDoubleTapReleaseTimes.removeAll()
    }

    func clearPendingDoubleTap(for action: ShortcutAction) {
        #if VOCE_LOCAL
        if action == .primaryRecording {
            fnFirstRelease = nil
            if fnPressTime != nil {
                fnInterrupted = true
                cancelFnHoldTimer()
            }
        }
        #endif
        if pendingDoubleTapReleaseTimes.removeValue(forKey: action) != nil {
            logger.notice("Cleared pending double tap action=\(action.storageName, privacy: .public)")
        }
    }

    func clearPendingModeDoubleTaps() {
        pendingDoubleTapReleaseTimes = pendingDoubleTapReleaseTimes.filter { action, _ in
            if case .mode = action { return false }
            return true
        }
    }

    func resetShortcutState(for action: ShortcutAction) {
        #if VOCE_LOCAL
        if action == .primaryRecording { resetLocalFnState() }
        #endif
        pendingDoubleTapReleaseTimes.removeValue(forKey: action)
        guard activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        shortcutPressStartTime = nil
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
    }

    func handleShortcutDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        #if VOCE_LOCAL
        if action == .primaryRecording {
            handleLocalFnDown(eventTime: eventTime, modeId: modeId)
            return
        }
        #endif

        if interruptedRecordingActions.remove(action) != nil {
            logger.notice("Ignored shortcut down after interruption action=\(action.storageName, privacy: .public)")
            return
        }

        if mode == .doubleTap && (!canHandleShortcutAction() || recordingState() == .starting) {
            logger.notice("Ignored double tap down state=\(String(describing: self.recordingState()), privacy: .public)")
            clearPendingDoubleTap(for: action)
            return
        }

        if mode != .doubleTap, let lastTrigger = lastShortcutPressTime,
            Date().timeIntervalSince(lastTrigger) < shortcutPressCooldown
        {
            logger.notice("Ignored shortcut down during cooldown action=\(action.storageName, privacy: .public)")
            return
        }

        guard !isShortcutPressed else {
            logger.notice("Ignored shortcut down because another press is active")
            return
        }
        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeShortcutIsDoubleTap = mode == .doubleTap
        activeShortcutCanCancelAccidentalStart = mode != .doubleTap && canCurrentShortcutPressCancelAccidentalStart
        if mode != .doubleTap {
            lastShortcutPressTime = Date()
        }
        shortcutPressStartTime = eventTime

        switch mode {
        case .toggle, .hybrid:
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .doubleTap:
            break
        }
    }

    func handleShortcutUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        #if VOCE_LOCAL
        if action == .primaryRecording {
            await handleLocalFnUp(eventTime: eventTime, modeId: modeId)
            return
        }
        #endif

        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            logger.notice("Ignored shortcut up without matching down action=\(action.storageName, privacy: .public) pressed=\(self.isShortcutPressed, privacy: .public)")
            return
        }
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false

        switch mode {
        case .toggle:
            isHandsFreeRecording = true

        case .pushToTalk:
            if isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .hybrid:
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration >= hybridPressThreshold && recordingState() == .recording {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            } else {
                isHandsFreeRecording = true
            }

        case .doubleTap:
            guard canHandleShortcutAction(), recordingState() != .starting else {
                logger.notice("Ignored double tap up state=\(String(describing: self.recordingState()), privacy: .public)")
                clearPendingDoubleTap(for: action)
                break
            }
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration < 0 || pressDuration > doubleTapThreshold {
                logger.notice("Ignored double tap press duration=\(pressDuration, privacy: .public)")
                pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            } else if let firstRelease = pendingDoubleTapReleaseTimes.removeValue(forKey: action),
                eventTime - firstRelease >= 0,
                eventTime - firstRelease <= doubleTapThreshold
            {
                logger.notice("Accepted double tap action=\(action.storageName, privacy: .public) releaseInterval=\(eventTime - firstRelease, privacy: .public)")
                await toggleRecorderPanel(modeId)
                isHandsFreeRecording = isRecorderVisible()
            } else {
                logger.notice("Waiting for second tap action=\(action.storageName, privacy: .public) pressDuration=\(pressDuration, privacy: .public)")
                pendingDoubleTapReleaseTimes[action] = eventTime
            }
        }

        shortcutPressStartTime = nil
    }

    func handleInterruption(action: ShortcutAction) async {
        #if VOCE_LOCAL
        if action == .primaryRecording {
            clearPendingDoubleTap(for: action)
            if fnRecordingKind == .held {
                fnCancelRequested = true
                if !fnStarting { await finishLocalFnRecording(cancel: true) }
            }
            return
        }
        #endif
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions.insert(action)
            }
            return
        }

        if activeShortcutIsDoubleTap {
            isShortcutPressed = false
            shortcutPressStartTime = nil
            activeRecordingShortcutAction = nil
            activeShortcutCanCancelAccidentalStart = false
            activeShortcutIsDoubleTap = false
            pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            return
        }

        guard activeShortcutCanCancelAccidentalStart else { return }

        reset()
        await cancelRecording()
    }

    #if VOCE_LOCAL
    /// Uses physical Fn edges: two short taps latch, a held key records until release.
    private func handleLocalFnDown(eventTime: TimeInterval, modeId: UUID?) {
        guard eventTime >= fnLastEventTime, fnPressTime == nil else { return }
        fnLastEventTime = eventTime
        fnPressTime = eventTime
        fnInterrupted = false
        if fnStarting, fnRecordingKind == .handsFree { return }
        guard !fnStarting, !fnStopping, canHandleShortcutAction() else {
            fnInterrupted = true
            fnFirstRelease = nil
            return
        }
        if recordingState() == .recording { return }
        fnRecordingKind = nil
        guard recordingState() == .idle,
            fnLastStopTime.map({ Date().timeIntervalSince($0) >= shortcutPressCooldown }) ?? true
        else {
            fnInterrupted = true
            fnFirstRelease = nil
            return
        }
        let token = UUID()
        fnHoldToken = token
        fnHoldTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self, self.fnHoldToken == token, self.fnPressTime != nil,
                !self.fnInterrupted, self.recordingState() == .idle,
                self.canHandleShortcutAction(), !self.fnStarting, !self.fnStopping
            else { return }
            self.fnFirstRelease = nil
            // Releasing Fn must cancel only the timer, never the engine startup task.
            self.fnHoldTask = nil
            self.fnHoldToken = nil
            await self.startLocalFnRecording(kind: .held, modeId: modeId)
        }
    }

    private func handleLocalFnUp(eventTime: TimeInterval, modeId: UUID?) async {
        guard let pressedAt = fnPressTime, eventTime >= fnLastEventTime else { return }
        fnLastEventTime = eventTime
        fnPressTime = nil
        cancelFnHoldTimer()
        if fnRecordingKind == .held {
            fnStopRequested = true
            if !fnStarting { await finishLocalFnRecording(cancel: fnCancelRequested) }
            return
        }
        guard !fnInterrupted else { return }
        // A tap can stop even while the asynchronous recorder start is finishing.
        if fnRecordingKind == .handsFree && fnStarting {
            fnStopRequested = true
            return
        }
        guard !fnStopping, canHandleShortcutAction() else { fnFirstRelease = nil; return }
        if recordingState() == .recording {
            await finishLocalFnRecording(cancel: false)
            return
        }
        guard recordingState() == .idle, !fnStarting else { fnFirstRelease = nil; return }
        let duration = eventTime - pressedAt
        if duration >= hybridPressThreshold {
            // Main-actor contention may deliver release before the delayed hold task.
            fnStopRequested = true
            await startLocalFnRecording(kind: .held, modeId: modeId)
        } else if let firstRelease = fnFirstRelease,
            eventTime - firstRelease >= 0, eventTime - firstRelease <= doubleTapThreshold {
            fnFirstRelease = nil
            await startLocalFnRecording(kind: .handsFree, modeId: modeId)
        } else {
            fnFirstRelease = eventTime
        }
    }

    /// Keeps release/cancel intent until engine startup returns, then finishes once.
    private func startLocalFnRecording(kind: FnRecordingKind, modeId: UUID?) async {
        fnStarting = true
        fnRecordingKind = kind
        fnCancelRequested = false
        await toggleRecorderPanel(modeId)
        fnStarting = false
        guard recordingState() == .recording else {
            fnRecordingKind = nil
            fnStopRequested = false
            fnCancelRequested = false
            return
        }
        if fnStopRequested || fnCancelRequested {
            await finishLocalFnRecording(cancel: fnCancelRequested)
        }
    }

    private func finishLocalFnRecording(cancel: Bool) async {
        guard !fnStopping else { return }
        fnStopping = true
        fnRecordingKind = nil
        fnFirstRelease = nil
        fnStopRequested = false
        fnCancelRequested = false
        fnLastStopTime = Date()
        if cancel { await cancelRecording() }
        else if recordingState() == .recording { await toggleRecorderPanel(nil) }
        fnStopping = false
    }

    private func cancelFnHoldTimer() {
        fnHoldToken = nil
        fnHoldTask?.cancel()
        fnHoldTask = nil
    }

    private func resetLocalFnState() {
        cancelFnHoldTimer()
        fnPressTime = nil
        fnFirstRelease = nil
        fnInterrupted = true
        if fnStarting { fnCancelRequested = true }
        else { fnRecordingKind = nil; fnStopRequested = false; fnCancelRequested = false }
    }
    #endif

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && recordingState() == .idle
    }
}
