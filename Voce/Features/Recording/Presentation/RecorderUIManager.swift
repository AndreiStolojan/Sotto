import AppKit
import Combine
import Foundation
import SwiftUI
import os

enum RecorderPanelStyle: String, CaseIterable, Identifiable {
    case notch
    case mini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch:
            return String(localized: "Notch")
        case .mini:
            return String(localized: "Mini")
        }
    }

    static var stored: RecorderPanelStyle {
        let rawValue = UserDefaults.standard.string(forKey: "RecorderType") ?? RecorderPanelStyle.mini.rawValue
        return RecorderPanelStyle(rawValue: rawValue) ?? .mini
    }
}

@MainActor
protocol RecorderPanelPresenting: AnyObject {
    var isRecorderPanelVisible: Bool { get }
    func dismissRecorderPanel() async
}

@MainActor
class RecorderUIManager: ObservableObject, RecorderPanelPresenting {
    @Published var recorderPanelStyle: RecorderPanelStyle = .stored {
        didSet {
            guard oldValue != recorderPanelStyle else { return }
            rebuildVisiblePanel(previousStyle: oldValue)
            UserDefaults.standard.set(recorderPanelStyle.rawValue, forKey: "RecorderType")
        }
    }

    var recorderType: String {
        get { recorderPanelStyle.rawValue }
        set { recorderPanelStyle = RecorderPanelStyle(rawValue: newValue) ?? .mini }
    }

    @Published var isRecorderPanelVisible = false {
        didSet {
            guard oldValue != isRecorderPanelVisible else { return }

            if isRecorderPanelVisible {
                #if VOCE_LOCAL
                notchLink.connect()
                #endif
                showRecorderPanel()
            } else {
                hideRecorderPanel()
            }
        }
    }

    private var notchWindowManager: NotchWindowManager?
    private var miniWindowManager: MiniWindowManager?
    private var panelInvalidationTask: Task<Void, Never>?
    private var didSetupNotifications = false
    private var lifecycleCancellable: AnyCancellable?
    #if VOCE_LOCAL
    let dockVisibility = DockVisibilityController()
    private var dockRecordingCancellable: AnyCancellable?
    let notchLink = NotchLink()
    private var notchReplacementCancellable: AnyCancellable?
    /// True while Eclipse shows the dictation, or a fresh connection has not said yet whether it will,
    /// and the window holds no assistant conversation, which only the window can show.
    private var notchReplacesRecorder = false

    /// Lets Eclipse show the dictation instead of the bottom recorder while it runs. Off by default.
    @Published var showsDictationInEclipse = UserDefaults.standard.bool(forKey: "ShowDictationInEclipse") {
        didSet {
            UserDefaults.standard.set(showsDictationInEclipse, forKey: "ShowDictationInEclipse")
            notchLink.isEnabled = showsDictationInEclipse
        }
    }

    /// Turns on Dock auto-hide while the bottom recorder shows, so the pill has room. Off by default;
    /// it toggles a system-wide preference with Option-Command-D and restores it afterwards.
    @Published var hidesDockWhileRecording = UserDefaults.standard.bool(forKey: "HideDockWhileRecording") {
        didSet { UserDefaults.standard.set(hidesDockWhileRecording, forKey: "HideDockWhileRecording") }
    }
    #endif

    private weak var engine: VoceEngine?
    private var recorder: Recorder?

    private let logger = Logger(subsystem: "ro.andrei.Voce", category: "RecorderUIManager")

    init() {}

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Call after VoceEngine is created to break the circular init dependency.
    func configure(engine: VoceEngine, recorder: Recorder) {
        self.engine = engine
        self.recorder = recorder
        #if VOCE_LOCAL
        // Eclipse replaces the bottom window while it presents, or a fresh connection has not said yet whether it will,
        // unless the window holds an assistant conversation, which only the window can show.
        let notchReplacement = notchLink.$notchPresenting
            .combineLatest(notchLink.$isPresenceKnown, engine.assistantSession.$phase.map { $0 != .inactive })
            .map { presenting, presenceKnown, assistantVisible in
                (presenting || !presenceKnown) && !assistantVisible
            }
            .removeDuplicates()
        // The Dock makes room for the bottom window only: never for the notch recorder, never while
        // Eclipse replaces it, and only when the setting is on.
        dockRecordingCancellable = engine.$recordingState
            .combineLatest(notchReplacement, $recorderPanelStyle, $hidesDockWhileRecording)
            .map { state, notchReplaces, style, hidesDock in
                guard hidesDock, style == .mini else { return false }
                // Keep the bottom recorder visible until its processing indicator finishes.
                return switch state {
                case .starting, .recording, .transcribing, .enhancing: !notchReplaces
                case .idle, .busy: false
                }
            }
            .removeDuplicates()
            .sink { [weak self] needsRoom in
                if needsRoom {
                    self?.dockVisibility.hideForRecording()
                } else {
                    self?.dockVisibility.restore()
                }
            }
        notchReplacementCancellable = notchReplacement
            .sink { [weak self] replaces in self?.notchReplacementChanged(replaces) }
        notchLink.configure(
            engine: engine,
            recorder: recorder,
            isEnabled: showsDictationInEclipse,
            onStop: { [weak self] in await self?.stopFromNotch() },
            onCancel: { [weak self] in await self?.cancelFromNotch() }
        )
        #endif
        setupNotifications()
    }

    // MARK: - Recorder Panel Management

    /// Shows the bottom recorder window unless Eclipse replaces it.
    private func showRecorderPanel() {
        #if VOCE_LOCAL
        guard !notchReplacesRecorder else { return }
        #endif
        guard let engine = engine, let recorder = recorder else { return }

        let shown: Bool

        switch recorderPanelStyle {
        case .notch:
            if notchWindowManager == nil {
                notchWindowManager = NotchWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            shown = notchWindowManager?.show() ?? false
        case .mini:
            if miniWindowManager == nil {
                miniWindowManager = MiniWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            shown = miniWindowManager?.show() ?? false
        }

        if shown {
            logger.notice("Showed recorder panel style=\(self.recorderPanelStyle.rawValue, privacy: .public)")
        } else {
            // Only reachable with no screens at all. Recording still works, so the session is
            // left running rather than cancelled, but it runs without any UI — say so loudly,
            // because this is exactly the symptom users report.
            logger.error("Recorder panel could not be shown style=\(self.recorderPanelStyle.rawValue, privacy: .public) screens=\(NSScreen.screens.count, privacy: .public)")
        }
    }

    private func hideRecorderPanel() {
        // `dismissRecorderPanel()` calls this directly and then clears the flag, which calls it
        // again, so this deliberately stays at debug level.
        logger.debug("Hiding recorder panel style=\(self.recorderPanelStyle.rawValue, privacy: .public)")
        switch recorderPanelStyle {
        case .notch:
            notchWindowManager?.hide()
        case .mini:
            miniWindowManager?.hide()
        }
    }

    #if VOCE_LOCAL
    // MARK: - Eclipse

    /// One indicator only: while the recorder is logically visible, the window hides whenever Eclipse replaces it.
    /// `@Published` emits before its value changes, so the new state is passed in rather than recomputed.
    private func notchReplacementChanged(_ replaces: Bool) {
        notchReplacesRecorder = replaces
        guard isRecorderPanelVisible else { return }
        if replaces {
            hideRecorderPanel()
        } else {
            showRecorderPanel()
        }
    }

    /// Stop clicked in the notch: the same as the recorder's Stop button, only while recording.
    private func stopFromNotch() async {
        guard isActivelyRecording else { return }
        await toggleRecorderPanel()
    }

    /// Cancel clicked in the notch: the same as Escape, ignored when idle.
    private func cancelFromNotch() async {
        guard isRecorderPanelVisible, let engine, engine.recordingState != .idle else { return }
        await cancelRecording()
    }
    #endif

    // MARK: - Panel Invalidation

    /// Recorder panels must not outlive a sleep/wake cycle or a display reconfiguration.
    ///
    /// `NotchWindowManager.show()` already rebuilds a panel that is not on screen, so the work
    /// here is only about the panel that is currently *hidden but retained*: dropping it frees
    /// the window early and keeps `destroyWindow()` on a path that actually runs. When a
    /// dictation is in progress the panel stays put and is only repositioned, so an active
    /// session never loses its UI.
    ///
    /// `didChangeScreenParameters` fires several times per reconfiguration and displays need a
    /// moment to settle afterwards, so the work is debounced and re-armed on every event
    /// instead of guessing a single settle delay.
    private func invalidatePanels(reason: String) {
        panelInvalidationTask?.cancel()
        panelInvalidationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.applyPanelInvalidation(reason: reason)
        }
    }

    private func applyPanelInvalidation(reason: String) {
        guard isRecorderPanelVisible else {
            logger.notice("Discarding idle recorder panels (\(reason, privacy: .public))")
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
            return
        }

        logger.notice("Repositioning visible recorder panel (\(reason, privacy: .public))")
        showRecorderPanel()
    }

    private func rebuildVisiblePanel(previousStyle: RecorderPanelStyle) {
        guard isRecorderPanelVisible else { return }

        switch previousStyle {
        case .notch:
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
        case .mini:
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard self.isRecorderPanelVisible else { return }
            self.showRecorderPanel()
        }
    }

    // MARK: - Recorder Panel Management

    func toggleRecorderPanel(modeId: UUID? = nil) async {
        guard let engine = engine else { return }

        if isRecorderPanelVisible {
            switch engine.recordingState {
            case .recording:
                await engine.toggleRecord(modeId: modeId)
            case .starting, .transcribing, .enhancing:
                await cancelRecording()
            case .idle:
                if engine.assistantSession.canSendFollowUp {
                    SoundManager.shared.playStartSound()
                    await engine.toggleRecord(
                        modeId: modeId,
                        isAssistantFollowUp: true
                    )
                } else {
                    await dismissRecorderPanel()
                }
            case .busy:
                await dismissRecorderPanel()
            }
        } else {
            SoundManager.shared.playStartSound()
            isRecorderPanelVisible = true
            await engine.toggleRecord(modeId: modeId)
        }
    }

    func finishRecordingAndSend() async {
        guard isRecorderPanelVisible, let engine, engine.recordingState == .recording else { return }
        await engine.toggleRecord(sendAfterPaste: true)
    }

    var isActivelyRecording: Bool {
        isRecorderPanelVisible && engine?.recordingState == .recording
    }

    var recordingStatePublisher: AnyPublisher<RecordingState, Never>? {
        engine?.$recordingState.eraseToAnyPublisher()
    }

    func dismissRecorderPanel() async {
        guard let engine = engine else { return }

        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
    }

    func resetOnLaunch() async {
        guard let engine = engine else { return }
        logger.notice("Resetting recording state on launch")
        await engine.resetRecordingSession()
        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
    }

    func cancelRecording() async {
        guard let engine = engine else { return }
        await engine.cancelRecording()
        await dismissRecorderPanel()
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        guard !didSetupNotifications else { return }
        didSetupNotifications = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleRecorderPanelNotification),
            name: .toggleRecorderPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissRecorderPanelNotification),
            name: .dismissRecorderPanel,
            object: nil
        )
        lifecycleCancellable = LifecycleObserver.shared.publisher(
            for: [.systemDidWake, .displaysDidWake, .screenConfigurationChanged]
        ).sink { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .systemDidWake:
                    self.invalidatePanels(reason: "system wake")
                case .displaysDidWake:
                    self.invalidatePanels(reason: "displays wake")
                case .screenConfigurationChanged:
                    self.invalidatePanels(reason: "screen parameters changed")
                default:
                    break
                }
            }
        }
    }

    @objc public func handleToggleRecorderPanelNotification() {
        Task {
            await toggleRecorderPanel()
        }
    }

    @objc public func handleDismissRecorderPanelNotification() {
        Task {
            switch engine?.recordingState {
            case .starting, .recording, .transcribing, .enhancing:
                await cancelRecording()
            case .idle, .busy, nil:
                await dismissRecorderPanel()
            }
        }
    }
}
