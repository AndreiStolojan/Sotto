import Foundation

enum BackupCategory: String, CaseIterable, Hashable {
    case general
    case prompts
    case modes
    case dictionary

    var title: String {
        switch self {
        case .general:
            return String(localized: "General Settings")
        case .prompts:
            return String(localized: "Custom Prompts")
        case .modes:
            return String(localized: "Modes")
        case .dictionary:
            return String(localized: "Dictionary")
        }
    }
}

struct GeneralBackup: Codable {
    let primaryRecordingShortcut: ShortcutBackup?
    let secondaryRecordingShortcut: ShortcutBackup?
    let pasteLastTranscriptionShortcut: ShortcutBackup?
    let pasteLastEnhancementShortcut: ShortcutBackup?
    let retryLastTranscriptionShortcut: ShortcutBackup?
    let cancelRecorderShortcut: ShortcutBackup?
    let openHistoryWindowShortcut: ShortcutBackup?
    let quickAddToDictionaryShortcut: ShortcutBackup?
    let primaryRecordingShortcutRawValue: String?
    let secondaryRecordingShortcutRawValue: String?
    let primaryRecordingShortcutModeRawValue: String?
    let secondaryRecordingShortcutModeRawValue: String?
    let launchAtLoginEnabled: Bool?
    let isMenuBarOnly: Bool?
    let recorderType: String?
    let appAppearancePreference: String?
    let appLanguagePreference: String?
    let isTranscriptionCleanupEnabled: Bool?
    let transcriptionRetentionMinutes: Int?
    let isAudioCleanupEnabled: Bool?
    let audioRetentionPeriod: Int?

    let isSystemMuteEnabled: Bool?
    let isPauseMediaEnabled: Bool?
    let audioResumptionDelay: Double?
    let isTextFormattingEnabled: Bool?
    let isExperimentalFeaturesEnabled: Bool?
    let restoreClipboardAfterPaste: Bool?
    let clipboardRestoreDelay: Double?
    let finishAndSendKey: String?
    let isAutoLearnDictionaryEnabled: Bool?
    let autoLearnReviewSchedule: String?
    let autoLearnProvider: String?
    let autoLearnModel: String?
}

struct WordBackup: Codable {
    let word: String

    init(word: String) {
        self.word = word
    }
}

struct BackupFile: Codable {
    let version: String
    let customPrompts: [CustomPrompt]
    let modeConfigs: [ModeConfig]
    let modeShortcuts: [String: ShortcutBackup]?
    let vocabularyWords: [WordBackup]?
    let wordReplacements: [String: String]?
    let generalSettings: GeneralBackup?
    let customEmojis: [String]?

    private enum CodingKeys: String, CodingKey {
        case version, customPrompts, modeConfigs, modeShortcuts, vocabularyWords, wordReplacements, generalSettings,
            customEmojis
        case legacyModeConfigs = "powerModeConfigs"
        case legacyModeShortcuts = "powerModeShortcuts"
    }

    init(
        version: String, customPrompts: [CustomPrompt], modeConfigs: [ModeConfig],
        modeShortcuts: [String: ShortcutBackup]?, vocabularyWords: [WordBackup]?, wordReplacements: [String: String]?,
        generalSettings: GeneralBackup?, customEmojis: [String]?
    ) {
        self.version = version
        self.customPrompts = customPrompts
        self.modeConfigs = modeConfigs
        self.modeShortcuts = modeShortcuts
        self.vocabularyWords = vocabularyWords
        self.wordReplacements = wordReplacements
        self.generalSettings = generalSettings
        self.customEmojis = customEmojis
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        customPrompts = try container.decodeIfPresent([CustomPrompt].self, forKey: .customPrompts) ?? []
        modeConfigs =
            try container.decodeIfPresent([ModeConfig].self, forKey: .modeConfigs)
            ?? container.decodeIfPresent([ModeConfig].self, forKey: .legacyModeConfigs)
            ?? []
        modeShortcuts =
            try container.decodeIfPresent([String: ShortcutBackup].self, forKey: .modeShortcuts)
            ?? container.decodeIfPresent([String: ShortcutBackup].self, forKey: .legacyModeShortcuts)
        vocabularyWords = try container.decodeIfPresent([WordBackup].self, forKey: .vocabularyWords)
        wordReplacements = try container.decodeIfPresent([String: String].self, forKey: .wordReplacements)
        generalSettings = try container.decodeIfPresent(GeneralBackup.self, forKey: .generalSettings)
        customEmojis = try container.decodeIfPresent([String].self, forKey: .customEmojis)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(customPrompts, forKey: .customPrompts)
        try container.encode(modeConfigs, forKey: .modeConfigs)
        try container.encodeIfPresent(modeShortcuts, forKey: .modeShortcuts)
        try container.encodeIfPresent(vocabularyWords, forKey: .vocabularyWords)
        try container.encodeIfPresent(wordReplacements, forKey: .wordReplacements)
        try container.encodeIfPresent(generalSettings, forKey: .generalSettings)
        try container.encodeIfPresent(customEmojis, forKey: .customEmojis)
    }
}
