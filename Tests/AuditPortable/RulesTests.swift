import Foundation

/// Exercises privacy boundaries and corrupt-state recovery without app or OS mocks.
@main
struct RulesTests {
    struct CheckFailure: Error { let message: String }
    struct Record: Codable, Equatable { let word: String }
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else { throw CheckFailure(message: message) }
    }

    static func main() throws {
        let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try websiteBoundaries()
        try recordingOwnership(in: scratch)
        try jsonRecovery(in: scratch)
        print("PASS: \(checks) portable production-rule checks")
    }

    private static func websiteBoundaries() throws {
        let cases: [(String, String, Bool)] = [
            ("https://slack.com", "slack.com", true),
            ("https://team.slack.com/channel", "slack.com", true),
            ("https://www.slack.com/channel", "https://www.slack.com/", true),
            ("https://SLACK.COM/channel", "slack.com", true),
            ("https://slack.com.attacker.example", "slack.com", false),
            ("https://notslack.com", "slack.com", false),
            ("https://example.net/?slack.com", "slack.com", false),
            ("https://slack.com@example.net", "slack.com", false),
            ("https://example.net/slack.com", "slack.com", false),
            ("https://icloud.com/mail/inbox", "icloud.com/mail", true),
            ("https://icloud.com/mailbox", "icloud.com/mail", false),
            ("http://localhost:3000/editor", "localhost:3000", true),
            ("http://localhost:3001/editor", "localhost:3000", false),
            ("https://example.com", "", false),
        ]
        for (url, website, expected) in cases {
            try check(ModeWebsiteMatcher.matches(url: url, website: website) == expected,
                      "Website boundary: \(url) against \(website)")
        }
    }

    private static func recordingOwnership(in scratch: URL) throws {
        let files = FileManager.default
        let recordings = scratch.appendingPathComponent("Recordings", isDirectory: true)
        try files.createDirectory(at: recordings, withIntermediateDirectories: true)
        let owned = recordings.appendingPathComponent("owned.wav")
        let external = scratch.appendingPathComponent("external.wav")
        try Data([1]).write(to: owned)
        try Data([2]).write(to: external)
        try check(RecordingFileLocation.ownedFileURL(from: owned.absoluteString, in: recordings) == owned,
                  "An owned recording can be cleaned up")
        try check(RecordingFileLocation.ownedFileURL(from: external.absoluteString, in: recordings) == nil,
                  "An external recording cannot be deleted")
        try check(RecordingFileLocation.ownedFileURL(from: "https://example.com/audio.wav", in: recordings) == nil,
                  "Network URLs are never cleanup candidates")
        try check(RecordingFileLocation.ownedFileURL(from: recordings.absoluteString, in: recordings) == nil,
                  "The recording directory itself cannot be deleted")
        let link = recordings.appendingPathComponent("escape.wav")
        try files.createSymbolicLink(at: link, withDestinationURL: external)
        try check(RecordingFileLocation.ownedFileURL(from: link.absoluteString, in: recordings) == nil,
                  "A symlink cannot escape the recording directory")
        let traversal = recordings.appendingPathComponent("../external.wav")
        try check(RecordingFileLocation.ownedFileURL(from: traversal.absoluteString, in: recordings) == nil,
                  "Parent traversal cannot escape the recording directory")
        try check(files.fileExists(atPath: external.path), "Boundary checks leave external data intact")
    }

    private static func jsonRecovery(in scratch: URL) throws {
        let files = FileManager.default
        let url = scratch.appendingPathComponent("state.json")
        let decoded = try AutoLearnJSONArrayFile.decodeElements(Record.self,
            from: Data(#"[{"word":"știe"},null,7,"wrong",{"word":false},{"word":"works"}]"#.utf8))
        try check(decoded == [Record(word: "știe"), Record(word: "works")],
                  "Malformed entries cannot crash decoding or hide valid entries")
        let missing = try AutoLearnJSONArrayFile.load(Record.self, from: url, fileManager: files)
        try check(missing.isEmpty, "A missing state file starts empty")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: url)
        let recovered = try AutoLearnJSONArrayFile.load(Record.self, from: url, fileManager: files)
        try check(recovered.isEmpty, "Corrupt state can recover")
        let backups = try files.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state.corrupt-") }
        try check(backups.count == 1, "Corrupt state is preserved before a new save")
        let preserved = try Data(contentsOf: backups[0])
        try check(preserved == corrupt, "Recovery preserves the original bytes")
        try files.createDirectory(at: url, withIntermediateDirectories: false)
        var readFailed = false
        do {
            _ = try AutoLearnJSONArrayFile.load(Record.self, from: url, fileManager: files)
        } catch {
            readFailed = true
        }
        try check(readFailed, "A read error must propagate")
        try files.removeItem(at: url)
        try JSONEncoder().encode([Record(word: "retry")]).write(to: url)
        let retried = try AutoLearnJSONArrayFile.load(Record.self, from: url, fileManager: files)
        try check(retried == [Record(word: "retry")], "Loading can retry after a read failure")
    }
}
