#if VOCE_LOCAL
import AppKit
import Carbon.HIToolbox
import os

/// Temporarily toggles Dock auto-hide using the standard macOS shortcut, preserving app focus.
@MainActor
final class DockVisibilityController: NSObject {
    private let restorationKey = "VoceDockAutohideNeedsRestore"
    private let pendingTargetKey = "VoceDockAutohidePendingTarget"
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "ro.andrei.Voce", category: "DockVisibility")
    private var recordingActive = false
    private var isTerminating = false
    private var updateTask: Task<Void, Never>?

    override init() {
        super.init()
        restore()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func hideForRecording() {
        guard !isTerminating else { return }
        recordingActive = true
        updateDock()
    }

    func restore() {
        recordingActive = false
        updateDock()
    }

    /// Lets AppKit defer quit while an outstanding toggle settles, without blocking its event loop.
    func restoreBeforeTermination(timeout: Duration = .seconds(10)) async {
        isTerminating = true
        restore()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while updateTask != nil, clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
        if updateTask != nil {
            logger.error("Dock restoration still pending at quit; keeping next-launch recovery marker")
        }
    }

    /// Serializes toggles so a failed or very short start cannot leave the Dock hidden.
    private func updateDock() {
        guard updateTask == nil else { return }
        updateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.updateTask = nil }
            var unconfirmedPosts = 0
            while true {
                guard !Task.isCancelled else { return }
                // Settle a toggle left pending by a previous process or an earlier pass before
                // interpreting the current preference. A visible Dock may still have a hide queued.
                if let pendingTarget = self.defaults.object(forKey: self.pendingTargetKey) as? Bool {
                    let applied = await self.waitForToggle(pendingTarget)
                    guard !Task.isCancelled else { return }
                    self.defaults.removeObject(forKey: self.pendingTargetKey)
                    self.defaults.synchronize()
                    if !applied { unconfirmedPosts += 1 }
                }
                let target = self.recordingActive
                var ownsPreference = self.defaults.bool(forKey: self.restorationKey)
                if target && !ownsPreference {
                    // Preserve an already hidden Dock rather than showing it at stop.
                    guard !self.isAutoHidden else { return }
                    self.defaults.set(true, forKey: self.restorationKey)
                    self.defaults.synchronize()
                    ownsPreference = true
                }
                guard ownsPreference else { return }
                if self.isAutoHidden != target {
                    // The Dock ignores the shortcut while a fullscreen Space keeps it hidden anyway.
                    // Give up instead of blocking every later toggle; the next state change retries.
                    guard unconfirmedPosts < 2 else {
                        self.logger.notice("Dock ignored auto-hide shortcut enabled=\(target, privacy: .public); giving up until the next state change")
                        if !self.isAutoHidden {
                            self.defaults.removeObject(forKey: self.restorationKey)
                            self.defaults.synchronize()
                        }
                        return
                    }
                    self.defaults.set(target, forKey: self.pendingTargetKey)
                    self.defaults.synchronize()
                    guard self.toggleAutoHide() else {
                        self.defaults.removeObject(forKey: self.pendingTargetKey)
                        self.defaults.synchronize()
                        return
                    }
                    continue
                }
                unconfirmedPosts = 0
                if !target {
                    self.defaults.removeObject(forKey: self.restorationKey)
                    self.defaults.synchronize()
                }
                self.logger.notice("Dock auto-hide verified enabled=\(target, privacy: .public)")
                // A release or failed microphone start can arrive while macOS applies the shortcut.
                guard self.recordingActive != target else { return }
            }
        }
    }

    /// The Dock applies the shortcut within about half a second or not at all. Treat a longer
    /// wait as a lost or ignored event rather than holding every later toggle behind it.
    private func waitForToggle(_ target: Bool, timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while isAutoHidden != target {
            guard clock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return true
    }

    private var isAutoHidden: Bool {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesGetAppBooleanValue("autohide" as CFString, domain, nil)
    }

    private func toggleAutoHide() -> Bool {
        guard AXIsProcessTrusted(),
            let source = CGEventSource(stateID: .privateState)
        else {
            logger.error("Dock shortcut requires the existing Accessibility permission")
            return false
        }
        // Global macOS hotkeys need modifier edges, not only flags on the letter event.
        let keys: [(Int, Bool, CGEventFlags)] = [
            (kVK_Command, true, [.maskCommand]),
            (kVK_Option, true, [.maskCommand, .maskAlternate]),
            (kVK_ANSI_D, true, [.maskCommand, .maskAlternate]),
            (kVK_ANSI_D, false, [.maskCommand, .maskAlternate]),
            (kVK_Option, false, [.maskCommand]),
            (kVK_Command, false, [])
        ]
        let events = keys.compactMap { key, isDown, flags -> CGEvent? in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: isDown) else { return nil }
            event.flags = flags
            if key == kVK_Command || key == kVK_Option {
                event.type = .flagsChanged
            }
            return event
        }
        guard events.count == keys.count else { return false }
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: ShortcutMonitor.localDockEventTag)
            event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    @objc private func applicationWillTerminate() {
        // AppDelegate has already awaited restoration. Never post a second toggle here:
        // a shortcut still pending after the quit deadline cannot be retracted by cancellation.
        updateTask?.cancel()
    }
}
#endif
