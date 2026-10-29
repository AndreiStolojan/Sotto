import AVFoundation
import AppKit
import Foundation

@MainActor
final class SystemInfoService {
    static let shared = SystemInfoService()

    private init() {}

    func getSystemInfoString() -> String {
        let modeConfigurationInfo = getModeConfigurationInfo(
            for: ModeManager.shared.currentEffectiveConfiguration
        )
        let info = """
            === VOCE SYSTEM INFORMATION ===
            Generated: \(Self.englishTimestamp())

            APP INFORMATION:
            App Version: \(getAppVersion())
            Build Version: \(getBuildVersion())

            OPERATING SYSTEM:
            macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)

            HARDWARE INFORMATION:
            Device Model: \(getMacModel())
            CPU: \(getCPUInfo())
            Memory: \(getMemoryInfo())
            Architecture: \(getArchitecture())

            AUDIO SETTINGS:
            Input Mode: \(getAudioInputMode())
            Current Audio Device: \(getCurrentAudioDevice())
            Available Audio Devices: \(getAvailableAudioDevices())

            HOTKEY SETTINGS:
            Primary Shortcut: \(getPrimaryShortcut())
            Secondary Shortcut: \(getSecondaryShortcut())

            MODE CONFIGURATION:
            \(modeConfigurationInfo)

            UI SETTINGS:
            Hide Dock Icon: \(UserDefaults.standard.bool(forKey: "IsMenuBarOnly"))
            Recorder Style: \(UserDefaults.standard.string(forKey: "RecorderType") ?? "mini")

            RECORDING FEEDBACK:
            Sound Feedback: \(CustomSoundManager.shared.hasAnyRecordingSoundEnabled)
            Pause Media While Recording: \(UserDefaults.standard.bool(forKey: "isPauseMediaEnabled"))
            Mute Audio While Recording: \(UserDefaults.standard.bool(forKey: "isSystemMuteEnabled"))
            Audio Resumption Delay: \(UserDefaults.standard.double(forKey: "audioResumptionDelay"))s

            CLIPBOARD & PASTE SETTINGS:
            Restore Clipboard After Paste: \(UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste"))
            Clipboard Restore Delay: \(UserDefaults.standard.double(forKey: "clipboardRestoreDelay"))s
            Paste Method: \(PasteMethod.current().displayName)

            DATA CLEANUP SETTINGS:
            Auto-Delete Transcriptions: \(UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled))
            Transcription Retention: \(UserDefaults.standard.integer(forKey: CleanupSettingsKeys.transcriptionRetentionMinutes)) minutes
            Auto-Delete Audio Files: \(UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled))
            Audio Retention Period: \(UserDefaults.standard.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod)) days

            PERMISSIONS:
            Accessibility: \(getAccessibilityStatus())
            Screen Recording: \(getScreenRecordingStatus())
            Microphone: \(getMicrophoneStatus())
            """

        return info
    }

    func copySystemInfoToClipboard() {
        let info = getSystemInfoString()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(info, forType: .string)
    }

    private func getAppVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private func getBuildVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    private func getMacModel() -> String {
        systemString(for: "hw.model") ?? "Unknown"
    }

    private func getCPUInfo() -> String {
        systemString(for: "machdep.cpu.brand_string") ?? "Unknown"
    }

    /// Reads a bounded, terminated sysctl string. Missing properties are normal on some hardware.
    private func systemString(for name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0,
            size > 0, size <= 65_536
        else { return nil }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private func getMemoryInfo() -> String {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let gibibytes = Double(totalMemory) / 1_073_741_824
        return String(format: "%.2f GB (%llu bytes)", locale: Locale(identifier: "en_US_POSIX"), gibibytes, totalMemory)
    }

    private func getArchitecture() -> String {
        return SystemArchitecture.current
    }

    private func getAudioInputMode() -> String {
        if let mode = UserDefaults.standard.audioInputModeRawValue,
            let audioMode = AudioInputMode(rawValue: mode)
        {
            switch audioMode {
            case .systemDefault:
                return "System Default"
            case .custom:
                return "Custom Device"
            case .prioritized:
                return "Prioritized"
            }
        }
        return "System Default"
    }

    private func getCurrentAudioDevice() -> String {
        let audioManager = AudioDeviceManager.shared
        let deviceID = audioManager.getCurrentDevice()
        if deviceID != 0, let deviceName = audioManager.getDeviceName(deviceID: deviceID) {
            return deviceName
        }
        return "Unknown"
    }

    private func getAvailableAudioDevices() -> String {
        let devices = AudioDeviceManager.shared.availableDevices
        if devices.isEmpty {
            return "None detected"
        }
        return devices.map { $0.name }.joined(separator: ", ")
    }

    private func getPrimaryShortcut() -> String {
        shortcutDescription(for: .primaryRecording)
    }

    private func getSecondaryShortcut() -> String {
        shortcutDescription(for: .secondaryRecording)
    }

    private func shortcutDescription(for action: ShortcutAction) -> String {
        ShortcutStore.shortcut(for: action)?.displayString ?? ""
    }

    private func getModeConfigurationInfo(for mode: ModeConfig?) -> String {
        guard let mode else {
            return "No enabled mode"
        }

        let model = mode.selectedTranscriptionModelName.flatMap { modelName in
            TranscriptionModelRegistry.model(forSelectionKey: modelName, in: TranscriptionModelRegistry.models)
        }
        let modelDescription = model?.displayName
            ?? mode.selectedTranscriptionModelName
            ?? "Not configured"
        let languageDescription = getModeLanguageDescription(for: mode, model: model)
        let enhancementDescription = getModeEnhancementDescription(for: mode)

        return """
            Mode: \(mode.name)
            Transcription Model: \(modelDescription)
            Language: \(languageDescription)
            Enhancement: \(enhancementDescription)
            """
    }

    private func getModeLanguageDescription(for mode: ModeConfig, model: (any TranscriptionModel)?) -> String {
        guard let model else {
            return mode.selectedLanguage ?? "Not configured"
        }

        let language = TranscriptionLanguageSupport.validLanguageOrFallback(
            mode.selectedLanguage,
            for: model,
            realtimeEnabled: mode.isRealtimeTranscriptionEnabled
        )
        let displayName = TranscriptionLanguageSupport.languages(
            for: model,
            realtimeEnabled: mode.isRealtimeTranscriptionEnabled
        )[language]

        guard let displayName, displayName.caseInsensitiveCompare(language) != .orderedSame else {
            return language
        }
        return "\(displayName) (\(language))"
    }

    private func getModeEnhancementDescription(for mode: ModeConfig) -> String {
        guard mode.isAIEnhancementEnabled else {
            return "Disabled"
        }

        let configuration = [mode.selectedAIProvider, mode.selectedAIModel]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }

        return configuration.isEmpty ? "Enabled (Not configured)" : configuration.joined(separator: ", ")
    }

    private func getAccessibilityStatus() -> String {
        return AXIsProcessTrusted() ? "Granted" : "Not Granted"
    }

    private func getScreenRecordingStatus() -> String {
        return CGPreflightScreenCaptureAccess() ? "Granted" : "Not Granted"
    }

    private func getMicrophoneStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "Granted"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Determined"
        @unknown default:
            return "Unknown"
        }
    }

    private static func englishTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

}
