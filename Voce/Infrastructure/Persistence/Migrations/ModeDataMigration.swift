import Foundation

extension ModeManager {
    func migratedModeConfigurationData(for configKey: String) -> Data? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: configKey) {
            return data
        }

        guard let legacyData = defaults.data(forKey: LegacyModeDataKey.configurations) else {
            return nil
        }

        defaults.set(legacyData, forKey: configKey)
        return legacyData
    }

    func migrateLoadedModeConfigurationsIfNeeded() {
        var didChange = false

        for index in configurations.indices {
            var config = configurations[index]
            var changedConfig = false

            if config.selectedTranscriptionModelName == nil {
                config.selectedTranscriptionModelName = UserDefaults.standard.string(
                    forKey: "CurrentTranscriptionModel")
                changedConfig = true
            }

            if config.selectedLanguage == nil {
                config.selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "en"
                changedConfig = true
            }

            if config.selectedAIProvider == nil {
                config.selectedAIProvider = UserDefaults.standard.string(forKey: "selectedAIProvider")
                changedConfig = true
            }

            if config.selectedAIModel == nil,
                let provider = config.selectedAIProvider
            {
                config.selectedAIModel = UserDefaults.standard.string(forKey: "\(provider)SelectedModel")
                changedConfig = true
            }

            if config.isAIEnhancementEnabled && config.selectedPrompt == nil {
                config.selectedPrompt = UserDefaults.standard.string(forKey: "selectedPromptId")
                changedConfig = true
            }

            if changedConfig {
                configurations[index] = config
                didChange = true
            }
        }

        if migrateToLatinScriptFilterIfNeeded() {
            didChange = true
        }

        if didChange {
            saveConfigurations()
        }

        migrateLegacyShortcutStorageIfNeeded()
    }

    /// One-time move of Parakeet v3 and Ultra modes, and the global language, onto the Latin
    /// script filter after Ultra wrote a Cyrillic word into Romanian dictation (#5). Runs here, in
    /// memory at load and before any save, so no later raw-defaults migration overwrites it.
    /// Modes on other models keep their language; the mode editor can switch back to Auto-detect.
    private func migrateToLatinScriptFilterIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        let migratedKey = "VoceLatinScriptDefaultV1"
        guard !defaults.bool(forKey: migratedKey) else { return false }
        defaults.set(true, forKey: migratedKey)

        let latin = LanguageDictionary.latinScriptKey
        func offersLatinFilter(_ modelName: String?) -> Bool {
            guard let modelName,
                let model = TranscriptionModelRegistry.model(
                    forSelectionKey: modelName, in: TranscriptionModelRegistry.models)
            else { return false }
            return model.supportedLanguages[latin] != nil
        }

        if offersLatinFilter(defaults.string(forKey: "CurrentTranscriptionModel")) {
            defaults.set(latin, forKey: "SelectedLanguage")
        }

        var didChange = false
        for index in configurations.indices
        where offersLatinFilter(configurations[index].selectedTranscriptionModelName)
            && configurations[index].selectedLanguage != latin
        {
            configurations[index].selectedLanguage = latin
            didChange = true
        }
        return didChange
    }
    private func migrateLegacyShortcutStorageIfNeeded() {
        let defaults = UserDefaults.standard

        for config in configurations {
            let oldShortcutKey = "\(LegacyModeDataKey.shortcutPrefix)\(config.id.uuidString)"
            let newShortcutKey = ShortcutAction.mode(config.id).userDefaultsKey

            if defaults.object(forKey: newShortcutKey) == nil,
                let oldShortcutData = defaults.data(forKey: oldShortcutKey)
            {
                defaults.set(oldShortcutData, forKey: newShortcutKey)
            }

            let oldClearedKey = "\(oldShortcutKey)_cleared"
            let newClearedKey = "\(newShortcutKey)_cleared"
            if defaults.object(forKey: newClearedKey) == nil,
                defaults.object(forKey: oldClearedKey) != nil
            {
                defaults.set(defaults.bool(forKey: oldClearedKey), forKey: newClearedKey)
            }
        }
    }
}

private enum LegacyModeDataKey {
    static let configurations = "powerModeConfigurationsV2"
    static let shortcutPrefix = "Shortcut_powerMode_"
}
