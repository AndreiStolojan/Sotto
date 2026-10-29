import Foundation

/// Checks WhisperCoreMLArchive against crafted ZIP files. Portable: runs on macOS and in the
/// Linux Swift container, where only stored (uncompressed) entries can be extracted.
@main
struct CoreMLArchiveTests {
    private static var checks = 0
    private static var failures = 0
    private static let root = "ggml-base-encoder.mlmodelc"

    static func main() async {
        checkPathValidation()
        checkCentralDirectoryChecks()
        checkStoredExtraction()
        checkReplaceRestoresPrevious()
        await checkInstallRenamesRoot()
        print("\(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if condition() {
            print("PASS: \(description)")
        } else {
            failures += 1
            FileHandle.standardError.write(Data("FAIL: \(description)\n".utf8))
        }
    }

    /// One entry for the test ZIP writer. `mode` is the Unix mode stored in the external attributes.
    struct TestEntry {
        var name: String
        var data = Data()
        var mode: UInt32 = 0o100644
        var declaredSize: UInt32?
    }

    /// Writes a stored-only ZIP. `overlapSecond` points the second entry's local header at the first.
    static func makeZip(_ entries: [TestEntry], overlapSecond: Bool = false) -> Data {
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

        var body = Data()
        var central = Data()
        var offsets: [UInt32] = []
        for entry in entries {
            let name = Data(entry.name.utf8)
            let size = entry.declaredSize ?? UInt32(entry.data.count)
            offsets.append(UInt32(body.count))
            body += le32(0x0403_4b50) + le16(10) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            body += le32(size) + le32(size) + le16(name.count) + le16(0) + name + entry.data
        }
        if overlapSecond, offsets.count > 1 { offsets[1] = offsets[0] }
        for (entry, offset) in zip(entries, offsets) {
            let name = Data(entry.name.utf8)
            let size = entry.declaredSize ?? UInt32(entry.data.count)
            central += le32(0x0201_4b50) + le16(0x031e) + le16(10) + le16(0) + le16(0) + le16(0) + le16(0)
            central += le32(0) + le32(size) + le32(size) + le16(name.count) + le16(0) + le16(0) + le16(0)
            central += le16(0) + le32(entry.mode << 16) + le32(offset) + name
        }
        let end = le32(0x0605_4b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
            + le32(UInt32(central.count)) + le32(UInt32(body.count)) + le16(0)
        return body + central + end
    }

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voce-archive-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func readEntries(_ zip: Data, limits: WhisperCoreMLArchive.Limits = .init()) throws
        -> [WhisperCoreMLArchive.Entry]
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("a.zip")
        try zip.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try WhisperCoreMLArchive.readEntries(from: handle, rootName: root, limits: limits)
    }

    private static func rejects(_ zip: Data, limits: WhisperCoreMLArchive.Limits = .init()) -> Bool {
        (try? readEntries(zip, limits: limits)) == nil
    }

    private static func checkPathValidation() {
        func accepts(_ name: String) -> Bool {
            (try? WhisperCoreMLArchive.validatePath(name, rootName: root)) != nil
        }
        expect(accepts("\(root)/weights/weight.bin") && accepts("\(root)/"), "encoder paths pass")
        expect(accepts("__MACOSX/\(root)/._model.mil"), "macOS metadata paths pass")
        expect(!accepts("\(root)/../../evil") && !accepts("../evil"), "parent traversal is rejected")
        expect(!accepts("/tmp/evil") && !accepts("\(root)//x") && !accepts("\(root)/./x"),
               "absolute, empty and dot components are rejected")
        expect(!accepts("ggml-base.bin") && !accepts("\(root)x/a"), "other top-level entries are rejected")
    }

    private static func checkCentralDirectoryChecks() {
        let good = makeZip([
            TestEntry(name: "\(root)/", mode: 0o040755),
            TestEntry(name: "\(root)/model.mil", data: Data("mil".utf8)),
        ])
        expect((try? readEntries(good))?.count == 2, "a valid archive lists its entries")

        expect(rejects(makeZip([TestEntry(name: "\(root)/link", data: Data("/etc".utf8), mode: 0o120777)])),
               "symlink entries are rejected from their mode bits")
        expect(rejects(makeZip([TestEntry(name: "\(root)/a\\..\\evil")])), "backslash names are rejected")
        expect(rejects(makeZip([TestEntry(name: "\(root)/a\nb")])), "control characters are rejected")
        expect(rejects(makeZip([TestEntry(name: "\(root)/a"), TestEntry(name: "\(root)/A")])),
               "case-insensitive duplicate names are rejected")
        expect(rejects(makeZip([TestEntry(name: "__MACOSX/x")])), "an archive without the encoder is rejected")
        expect(rejects(makeZip([TestEntry(name: "\(root)/a", data: Data("1".utf8)),
                                TestEntry(name: "\(root)/b", data: Data("1".utf8))], overlapSecond: true)),
               "overlapping entry data is rejected")
        expect(rejects(makeZip([TestEntry(name: "\(root)/a", data: Data("1".utf8), declaredSize: 1 << 20)])),
               "entry data running past the central directory is rejected")

        var small = WhisperCoreMLArchive.Limits()
        small.maxTotalUncompressedBytes = 4
        expect(rejects(makeZip([TestEntry(name: "\(root)/a", data: Data("12345".utf8))]), limits: small),
               "total uncompressed size above the cap is rejected before extraction")
        var few = WhisperCoreMLArchive.Limits()
        few.maxEntries = 1
        expect(rejects(makeZip([TestEntry(name: "\(root)/a"), TestEntry(name: "\(root)/b")]), limits: few),
               "entry count above the cap is rejected")
        expect(rejects(Data("not a zip".utf8)), "non-ZIP input is rejected")
    }

    private static func checkStoredExtraction() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zipURL = directory.appendingPathComponent("a.zip")
        try? makeZip([
            TestEntry(name: "\(root)/", mode: 0o040755),
            TestEntry(name: "\(root)/weights/weight.bin", data: Data("weights".utf8)),
            TestEntry(name: "__MACOSX/\(root)/._weight.bin", data: Data("meta".utf8)),
        ]).write(to: zipURL)
        let out = directory.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let encoder = try? WhisperCoreMLArchive.extract(zipURL: zipURL, rootName: root, into: out)
        let weights = encoder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("weights/weight.bin")) }
        expect(weights == Data("weights".utf8), "stored entries extract under the encoder")
        expect((try? FileManager.default.contentsOfDirectory(atPath: out.path)) == [root],
               "macOS metadata is not extracted")
    }

    private static func checkReplaceRestoresPrevious() {
        let fileManager = FileManager.default
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("installed")
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try? Data("old".utf8).write(to: destination.appendingPathComponent("file"))

        let missingSource = directory.appendingPathComponent("missing")
        let failed = (try? WhisperCoreMLArchive.replaceItem(
            at: destination, with: missingSource, backupDirectory: directory)) == nil
        expect(failed, "a failed commit throws")
        expect((try? Data(contentsOf: destination.appendingPathComponent("file"))) == Data("old".utf8),
               "a failed commit restores the previous install")

        let source = directory.appendingPathComponent("new")
        try? fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try? Data("new".utf8).write(to: source.appendingPathComponent("file"))
        try? WhisperCoreMLArchive.replaceItem(at: destination, with: source, backupDirectory: directory)
        expect((try? Data(contentsOf: destination.appendingPathComponent("file"))) == Data("new".utf8),
               "a successful commit replaces the install")
        let leftovers = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        expect(!leftovers.contains { $0.hasPrefix("previous-") }, "the backup is removed after commit")
    }

    /// The large-v2 archive root differs from the name whisper.cpp looks for.
    private static func checkInstallRenamesRoot() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zipURL = directory.appendingPathComponent("a.zip")
        try? makeZip([TestEntry(name: "\(root)/model.mil", data: Data("mil".utf8))]).write(to: zipURL)
        let models = directory.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)

        let installed = try? await WhisperCoreMLArchive.install(
            zipURL: zipURL, archiveDirectoryName: root, installedName: "ggml-other-encoder.mlmodelc",
            stagingDirectory: directory, destinationDirectory: models)
        expect(installed?.lastPathComponent == "ggml-other-encoder.mlmodelc"
               && FileManager.default.fileExists(atPath: models.appendingPathComponent(
                   "ggml-other-encoder.mlmodelc/model.mil").path),
               "install renames the archive root to the installed name")
    }
}
