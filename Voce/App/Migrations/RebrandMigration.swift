import Foundation

/// One-time rename of the `VOICEINK_*` variables in saved Local CLI and custom command templates after
/// the app became Voce. Without it, saved templates would expand empty variables. Settings backups from
/// before the rename go through `renamed(_:)` on import for the same reason.
enum RebrandMigration {
    private static let migratedKey = "VoceRebrandV1"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey),
            let domainName = Bundle.main.bundleIdentifier,
            let domain = defaults.persistentDomain(forName: domainName)
        else { return }

        for (key, value) in domain {
            let newKey = renamed(key)
            switch value {
            case let text as String:
                defaults.set(renamed(text), forKey: newKey)
            case let data as Data:
                // Modes are stored as JSON data; other data values are left untouched.
                if let json = String(data: data, encoding: .utf8), renamed(json) != json {
                    defaults.set(Data(renamed(json).utf8), forKey: newKey)
                } else if newKey != key {
                    defaults.set(data, forKey: newKey)
                }
            default:
                if newKey != key { defaults.set(value, forKey: newKey) }
            }
            if newKey != key { defaults.removeObject(forKey: key) }
        }

        defaults.set(true, forKey: migratedKey)
    }

    /// Rewrites VoiceInk-era template variables in saved text.
    static func renamed(_ text: String) -> String {
        text.replacingOccurrences(of: "VOICEINK_", with: "VOCE_")
    }
}
