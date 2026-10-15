import Foundation

/// Names the Application Support folder that holds Voce's models and local data.
/// It follows the bundle ID, so the `Voce Dev` build (`ro.andrei.Voce.dev`) never touches the daily app's data.
enum AppStorageNamespace {
    static let applicationSupportDirectoryName = Bundle.main.bundleIdentifier ?? "ro.andrei.Voce"
}
