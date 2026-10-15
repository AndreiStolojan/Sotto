#if VOCE_LOCAL
import AppKit
import Combine
import os

/// Shows Sotto's dictation in Eclipse over its local socket and tracks whether Eclipse presents it.
/// Off by default. Once enabled, it connects whenever both apps run: at launch, when Eclipse's instances change,
/// after a dropped connection and before a recording. It never polls while idle.
@MainActor
final class NotchLink: ObservableObject {
    static let eclipseBundleID = "ro.andrei.NotchLab"

    /// True only while connected and Eclipse's last reply said it shows the dictation.
    @Published private(set) var notchPresenting = false
    /// False from opening a connection until Eclipse's first reply, or 200 ms if it never answers.
    /// Until then Voce cannot tell which indicator should show.
    @Published private(set) var isPresenceKnown = true

    /// Off means Sotto never connects and always uses its own recorder.
    var isEnabled = false {
        didSet {
            guard oldValue != isEnabled else { return }
            if isEnabled { connect() } else { disconnect() }
        }
    }

    private var socket: NotchSocket?
    private var state = NotchDictationState.idle
    private var recorder: Recorder?
    private var onStop: (@MainActor () async -> Void)?
    private var onCancel: (@MainActor () async -> Void)?
    private var stateCancellable: AnyCancellable?
    private var instancesCancellable: AnyCancellable?
    private var levelTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var presenceTimeoutTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "ro.andrei.Voce", category: "NotchLink")

    /// Starts following the engine and Eclipse's instances, then tries to connect once.
    func configure(
        engine: VoceEngine,
        recorder: Recorder,
        isEnabled: Bool,
        onStop: @escaping @MainActor () async -> Void,
        onCancel: @escaping @MainActor () async -> Void
    ) {
        self.recorder = recorder
        self.onStop = onStop
        self.onCancel = onCancel
        stateCancellable = engine.$recordingState
            .map(NotchDictationState.init)
            .removeDuplicates()
            .sink { [weak self] state in self?.update(state) }
        // Eclipse is an LSUIElement app, so macOS never posts didLaunchApplicationNotification for it.
        // Apple's suggested alternative is to observe runningApplications; it changes on the main run loop.
        // Any change counts, not only a launch: when one of two instances quits, the other takes over the socket.
        instancesCancellable = NSWorkspace.shared.publisher(for: \.runningApplications)
            .map { apps in Set(apps.filter { $0.bundleIdentifier == Self.eclipseBundleID }.map(\.processIdentifier)) }
            .removeDuplicates()
            .dropFirst()
            .filter { !$0.isEmpty }
            .sink { [weak self] _ in self?.retryConnect() }
        self.isEnabled = isEnabled
    }

    /// Opens the socket if enabled and not yet connected, then sends the current state as the hello.
    @discardableResult
    func connect() -> Bool {
        guard isEnabled else { return false }
        guard socket == nil else { return true }
        guard let socket = NotchSocket(
            path: Self.socketPath,
            onCommand: { [weak self] socket, command in self?.handle(command, from: socket) },
            onClose: { [weak self] socket in self?.handleClose(of: socket) }
        ) else { return false }
        logger.notice("Connected to Eclipse")
        self.socket = socket
        retryTask?.cancel()
        awaitPresence()
        send()
        if state == .recording { startLevels() }
        return true
    }

    private func disconnect() {
        retryTask?.cancel()
        levelTask?.cancel()
        socket?.disconnect()
        socket = nil
        notchPresenting = false
        settlePresence()
    }

    /// Eclipse answers the first message at once, so a short timeout only covers a stalled Eclipse.
    private func awaitPresence() {
        isPresenceKnown = false
        presenceTimeoutTask?.cancel()
        presenceTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.settlePresence()
        }
    }

    private func settlePresence() {
        presenceTimeoutTask?.cancel()
        isPresenceKnown = true
    }

    /// Eclipse binds its socket shortly after it launches or takes over from an instance that quit,
    /// so try a few times over about 3 seconds.
    private func retryConnect() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.isEnabled else { return }
                if self.connect() { return }
            }
        }
    }

    /// Sends every state change once; while recording, also sends the level 20 times per second.
    private func update(_ newState: NotchDictationState) {
        state = newState
        levelTask?.cancel()
        levelTask = nil
        send()
        if newState == .recording { startLevels() }
    }

    private func startLevels() {
        guard socket != nil else { return }
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, self.socket != nil else { return }
                self.send(level: self.recorder?.audioMeterSnapshot().averagePower ?? 0)
            }
        }
    }

    private func send(level: Double = 0) {
        socket?.send(NotchDictationMessage(state: state, level: level).line)
    }

    private func handle(_ command: NotchCommand, from source: NotchSocket) {
        guard source === socket else { return }
        switch command {
        case .presenting(let available):
            notchPresenting = available
            settlePresence()
        case .stop:
            Task { await onStop?() }
        case .cancel:
            Task { await onCancel?() }
        }
    }

    /// A dropped connection is retried at once; if Eclipse quit, its next launch reconnects instead.
    private func handleClose(of source: NotchSocket) {
        guard source === socket else { return }
        logger.notice("Eclipse disconnected")
        socket = nil
        levelTask?.cancel()
        notchPresenting = false
        settlePresence()
        retryConnect()
    }

    /// Built from the account's home directory, which this unsandboxed profile shares with Eclipse.
    private static var socketPath: String {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        // Eclipse keeps its socket in the folder of its old name, Notch Lab.
        return home + "/Library/Application Support/Notch Lab/notch.sock"
    }
}
#endif
