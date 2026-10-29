import Foundation

/// Loads the JSON array files that hold Auto Learn state without ever letting a
/// later save overwrite data that could not be read.
enum AutoLearnJSONArrayFile {
    /// Returns the stored elements, or an empty array when the file does not exist.
    ///
    /// Read errors propagate so the caller can retry later. A file that is not a
    /// JSON array is moved aside before returning empty, and unreadable elements
    /// are dropped one by one so a single bad record cannot strand the rest.
    static func load<Element: Decodable>(
        _: Element.Type,
        from fileURL: URL,
        fileManager: FileManager
    ) throws -> [Element] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        do {
            return try decodeElements(Element.self, from: data)
        } catch is DecodingError {
            try moveAside(fileURL, fileManager: fileManager)
            return []
        }
    }

    /// Decodes a JSON array element by element, skipping elements that fail.
    static func decodeElements<Element: Decodable>(
        _: Element.Type,
        from data: Data
    ) throws -> [Element] {
        try JSONDecoder().decode([LossyElement<Element>].self, from: data).compactMap(\.value)
    }

    /// Keeps the unreadable file next to the original so it can be inspected.
    private static func moveAside(_ fileURL: URL, fileManager: FileManager) throws {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = fileURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(timestamp)-\(UUID().uuidString)")
            .appendingPathExtension(fileURL.pathExtension)
        try fileManager.moveItem(at: fileURL, to: backupURL)
    }
}

/// Wraps one array element so a decoding failure becomes `nil` instead of
/// failing the whole array.
private struct LossyElement<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}
