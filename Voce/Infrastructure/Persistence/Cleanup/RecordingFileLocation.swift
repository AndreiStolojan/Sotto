import Foundation

/// Locates audio files that Sotto owns, so cleanup never deletes a file outside
/// the Recordings directory even when a stored URL points elsewhere.
enum RecordingFileLocation {
    /// The directory where recordings, imports and retranscriptions store audio.
    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppStorageNamespace.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Returns the file URL for a stored `audioFileURL` only when it names a
    /// direct child of `directory` after resolving symlinks and `..` segments.
    static func ownedFileURL(from storedURLString: String?, in directory: URL = recordingsDirectory) -> URL? {
        guard let storedURLString,
            let url = URL(string: storedURLString),
            url.isFileURL
        else { return nil }

        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let directoryURL = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard fileURL.deletingLastPathComponent().pathComponents == directoryURL.pathComponents,
            !fileURL.lastPathComponent.isEmpty
        else { return nil }
        return fileURL
    }
}
