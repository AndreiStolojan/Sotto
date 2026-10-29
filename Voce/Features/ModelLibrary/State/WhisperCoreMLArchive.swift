import Foundation
#if canImport(Compression)
import Compression
#endif

/// Installs a downloaded whisper.cpp Core ML encoder archive.
///
/// The archive is remote input, so the app reads the ZIP central directory itself instead of
/// parsing tool output. Before anything is written it checks entry count, total and per-entry
/// uncompressed size, entry paths (ASCII, under the expected root, no `.`/`..`/absolute/backslash),
/// file types (regular files and directories only, so no symlinks), duplicate names, encryption,
/// ZIP64 and overlapping entry data. Extraction then writes each file into a fresh staging
/// directory and stops as soon as an entry inflates past its declared size. Only a fully extracted
/// encoder replaces the installed copy, and the previous copy is restored if that move fails.
enum WhisperCoreMLArchive {
    enum ArchiveError: LocalizedError, Equatable {
        case malformed(String)
        case unsupported(String)
        case unsafeEntry(String)
        case tooLarge
        case missingEncoder
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let detail):
                return "The Core ML archive is damaged (\(detail))."
            case .unsupported(let detail):
                return "The Core ML archive uses an unsupported format (\(detail))."
            case .unsafeEntry(let name):
                return "The Core ML archive contains an unexpected entry: \(name)"
            case .tooLarge:
                return "The Core ML archive expands beyond the allowed size."
            case .missingEncoder:
                return "The Core ML archive does not contain the expected encoder."
            case .extractionFailed(let name):
                return "The Core ML archive could not be extracted: \(name)"
            }
        }
    }

    /// Caps checked against the central directory before extraction. The largest published encoder
    /// has 16 entries and expands to about 1.28 GB.
    struct Limits: Sendable {
        var maxEntries = 256
        var maxTotalUncompressedBytes: Int64 = 2 << 30
        var maxCentralDirectoryBytes = 1 << 20
    }

    struct Entry: Equatable {
        let name: String
        let isDirectory: Bool
        let isDeflated: Bool
        let compressedSize: Int64
        let uncompressedSize: Int64
        /// Offset of the entry data, after its local header.
        let dataOffset: Int64
    }

    static let metadataDirectoryName = "__MACOSX"
    private static let chunkSize = 1 << 20

    /// Extracts the `archiveDirectoryName` tree and installs it as `destinationDirectory/installedName`.
    /// Returns the installed directory.
    static func install(
        zipURL: URL,
        archiveDirectoryName: String,
        installedName: String,
        stagingDirectory: URL,
        destinationDirectory: URL,
        limits: Limits = Limits()
    ) async throws -> URL {
        let extractionDirectory = stagingDirectory.appendingPathComponent(
            "extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractionDirectory) }

        // Extraction is seconds of synchronous I/O, so it runs off the caller's executor.
        let extractTask = Task.detached(priority: .utility) {
            try extract(
                zipURL: zipURL, rootName: archiveDirectoryName, into: extractionDirectory, limits: limits)
        }
        let encoder = try await withTaskCancellationHandler {
            try await extractTask.value
        } onCancel: {
            extractTask.cancel()
        }
        try Task.checkCancellation()

        let destination = destinationDirectory.appendingPathComponent(installedName, isDirectory: true)
        try replaceItem(at: destination, with: encoder, backupDirectory: stagingDirectory)
        return destination
    }

    /// Moves `source` to `destination`. An existing destination is moved aside first and put back
    /// if the move fails, so a failed commit never loses the installed copy.
    static func replaceItem(at destination: URL, with source: URL, backupDirectory: URL) throws {
        let fileManager = FileManager.default
        let backup = backupDirectory.appendingPathComponent("previous-\(UUID().uuidString)")
        let hadPrevious = (try? fileManager.attributesOfItem(atPath: destination.path)) != nil

        if hadPrevious {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            if hadPrevious {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
        if hadPrevious {
            try? fileManager.removeItem(at: backup)
        }
    }

    /// Validates the archive, then writes the encoder tree into `directory`. Returns the extracted
    /// encoder directory.
    static func extract(zipURL: URL, rootName: String, into directory: URL, limits: Limits = Limits()) throws
        -> URL
    {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }

        let entries = try readEntries(from: handle, rootName: rootName, limits: limits)
        let encoder = directory.appendingPathComponent(rootName, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: encoder, withIntermediateDirectories: false)

        for entry in entries where !entry.name.hasPrefix(metadataDirectoryName + "/") {
            try Task.checkCancellation()
            let relative = entry.name.split(separator: "/").dropFirst().joined(separator: "/")
            guard !relative.isEmpty else { continue }
            let target = encoder.appendingPathComponent(relative, isDirectory: entry.isDirectory)

            if entry.isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: target.path),
                fileManager.createFile(atPath: target.path, contents: nil)
            else {
                throw ArchiveError.extractionFailed(entry.name)
            }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            try write(entry, from: handle, to: output)
        }

        return encoder
    }

    /// Reads and validates the central directory. Nothing is written.
    static func readEntries(from handle: FileHandle, rootName: String, limits: Limits = Limits()) throws -> [Entry] {
        let fileSize = Int64(try handle.seekToEnd())
        let directory = try readCentralDirectory(from: handle, fileSize: fileSize, limits: limits)

        var entries: [Entry] = []
        var seenNames = Set<String>()
        var totalUncompressed: Int64 = 0
        var dataRanges: [(start: Int64, end: Int64)] = []
        var containsEncoder = false
        var cursor = directory.bytes.startIndex

        for _ in 0..<directory.count {
            let bytes = directory.bytes
            guard cursor + 46 <= bytes.endIndex, bytes.uint32(at: cursor) == 0x0201_4b50 else {
                throw ArchiveError.malformed("central directory")
            }
            let madeByHost = bytes[cursor + 5]
            let flags = bytes.uint16(at: cursor + 8)
            let method = bytes.uint16(at: cursor + 10)
            let compressedSize = Int64(bytes.uint32(at: cursor + 20))
            let uncompressedSize = Int64(bytes.uint32(at: cursor + 24))
            let nameLength = Int(bytes.uint16(at: cursor + 28))
            let extraLength = Int(bytes.uint16(at: cursor + 30))
            let commentLength = Int(bytes.uint16(at: cursor + 32))
            let externalAttributes = bytes.uint32(at: cursor + 38)
            let localHeaderOffset = Int64(bytes.uint32(at: cursor + 42))
            let nameStart = cursor + 46
            cursor = nameStart + nameLength + extraLength + commentLength
            guard cursor <= bytes.endIndex else { throw ArchiveError.malformed("central directory") }

            let nameBytes = bytes[nameStart..<(nameStart + nameLength)]
            // ASCII only: no control characters, no Unicode normalization or case-folding surprises.
            guard !nameBytes.isEmpty, nameBytes.allSatisfy({ (0x20...0x7e).contains($0) && $0 != 0x5c }) else {
                throw ArchiveError.unsafeEntry(String(decoding: nameBytes, as: UTF8.self))
            }
            let name = String(decoding: nameBytes, as: UTF8.self)

            guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF,
                localHeaderOffset != 0xFFFF_FFFF
            else {
                throw ArchiveError.unsupported("ZIP64")
            }
            guard flags & 0x0041 == 0 else { throw ArchiveError.unsupported("encryption") }
            guard method == 0 || method == 8 else { throw ArchiveError.unsupported("compression method \(method)") }

            let isDirectory = name.hasSuffix("/")
            try validatePath(name, rootName: rootName)
            // Unix hosts store the file mode in the high 16 bits. Only regular files and directories pass.
            if madeByHost == 3 {
                let fileType = (externalAttributes >> 16) & 0o170000
                let expectedType: UInt32 = isDirectory ? 0o040000 : 0o100000
                guard fileType == 0 || fileType == expectedType else {
                    throw ArchiveError.unsafeEntry(name)
                }
            }
            guard !isDirectory || (compressedSize == 0 && uncompressedSize == 0) else {
                throw ArchiveError.unsafeEntry(name)
            }
            guard method == 8 || compressedSize == uncompressedSize else {
                throw ArchiveError.malformed(name)
            }
            let key = String(name.lowercased().trimmingSuffix("/"))
            guard seenNames.insert(key).inserted else { throw ArchiveError.unsafeEntry(name) }

            totalUncompressed += uncompressedSize
            guard seenNames.count <= limits.maxEntries, totalUncompressed <= limits.maxTotalUncompressedBytes else {
                throw ArchiveError.tooLarge
            }
            if name.split(separator: "/").first.map(String.init) == rootName { containsEncoder = true }

            // The local header must repeat the name; its own extra field may differ in length.
            try handle.seek(toOffset: UInt64(localHeaderOffset))
            let local = try handle.read(upToCount: 30 + nameLength) ?? Data()
            guard local.count == 30 + nameLength, local.uint32(at: local.startIndex) == 0x0403_4b50,
                Int(local.uint16(at: local.startIndex + 26)) == nameLength,
                local.suffix(nameLength) == nameBytes
            else {
                throw ArchiveError.malformed(name)
            }
            let dataOffset = localHeaderOffset + 30 + Int64(nameLength) + Int64(local.uint16(at: local.startIndex + 28))
            let dataEnd = dataOffset + compressedSize
            guard dataEnd <= directory.offset else { throw ArchiveError.malformed(name) }
            dataRanges.append((localHeaderOffset, dataEnd))
            entries.append(
                Entry(
                    name: name,
                    isDirectory: isDirectory,
                    isDeflated: method == 8,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    dataOffset: dataOffset
                ))
        }

        // Overlapping entries let a tiny archive expand many times (the "overlapping files" ZIP bomb).
        let sortedRanges = dataRanges.sorted { $0.start < $1.start }
        for (previous, next) in zip(sortedRanges, sortedRanges.dropFirst()) where previous.end > next.start {
            throw ArchiveError.malformed("overlapping entries")
        }
        guard containsEncoder else { throw ArchiveError.missingEncoder }
        return entries
    }

    /// Accepts `<root>/...` and `__MACOSX/...` paths built from plain components.
    static func validatePath(_ name: String, rootName: String) throws {
        var components = name.split(separator: "/", omittingEmptySubsequences: false)
        if name.hasSuffix("/") { components.removeLast() }
        guard let topLevel = components.first,
            topLevel == Substring(rootName) || topLevel == Substring(metadataDirectoryName),
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw ArchiveError.unsafeEntry(name)
        }
    }

    private static func readCentralDirectory(from handle: FileHandle, fileSize: Int64, limits: Limits) throws
        -> (bytes: Data, offset: Int64, count: Int)
    {
        // The end-of-central-directory record is 22 bytes plus a comment of up to 65535 bytes.
        let tailLength = min(fileSize, 22 + 0xFFFF)
        try handle.seek(toOffset: UInt64(fileSize - tailLength))
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        guard tail.count == Int(tailLength), tail.count >= 22 else { throw ArchiveError.malformed("too short") }

        var recordIndex: Int?
        var index = tail.endIndex - 22
        while index >= tail.startIndex {
            if tail.uint32(at: index) == 0x0605_4b50,
                index + 22 + Int(tail.uint16(at: index + 20)) == tail.endIndex
            {
                recordIndex = index
                break
            }
            index -= 1
        }
        guard let recordIndex else { throw ArchiveError.malformed("no end record") }

        let recordOffset = fileSize - Int64(tail.endIndex - recordIndex)
        if recordIndex - 20 >= tail.startIndex, tail.uint32(at: recordIndex - 20) == 0x0706_4b50 {
            throw ArchiveError.unsupported("ZIP64")
        }
        let diskNumber = tail.uint16(at: recordIndex + 4)
        let directoryDisk = tail.uint16(at: recordIndex + 6)
        let entriesOnDisk = tail.uint16(at: recordIndex + 8)
        let entryCount = tail.uint16(at: recordIndex + 10)
        let directorySize = Int64(tail.uint32(at: recordIndex + 12))
        let directoryOffset = Int64(tail.uint32(at: recordIndex + 16))

        guard entryCount != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else {
            throw ArchiveError.unsupported("ZIP64")
        }
        guard diskNumber == 0, directoryDisk == 0, entriesOnDisk == entryCount else {
            throw ArchiveError.unsupported("multi-part archive")
        }
        guard Int(entryCount) <= limits.maxEntries, directorySize <= Int64(limits.maxCentralDirectoryBytes) else {
            throw ArchiveError.tooLarge
        }
        guard directoryOffset + directorySize == recordOffset else {
            throw ArchiveError.malformed("central directory location")
        }

        try handle.seek(toOffset: UInt64(directoryOffset))
        let bytes = try handle.read(upToCount: Int(directorySize)) ?? Data()
        guard bytes.count == Int(directorySize) else { throw ArchiveError.malformed("central directory") }
        return (bytes, directoryOffset, Int(entryCount))
    }

    /// Copies or inflates one entry. Output beyond the declared size aborts the entry.
    private static func write(_ entry: Entry, from input: FileHandle, to output: FileHandle) throws {
        try input.seek(toOffset: UInt64(entry.dataOffset))
        var written: Int64 = 0
        let emit: (Data) throws -> Void = { data in
            written += Int64(data.count)
            guard written <= entry.uncompressedSize else { throw ArchiveError.malformed(entry.name) }
            try output.write(contentsOf: data)
        }

        if entry.isDeflated {
            #if canImport(Compression)
            // Apple's zlib algorithm is raw DEFLATE (RFC 1951), the ZIP method 8 format.
            let filter = try OutputFilter(.decompress, using: .zlib, bufferCapacity: chunkSize) { data in
                if let data { try emit(data) }
            }
            try copyCompressedBytes(of: entry, from: input) { try filter.write($0) }
            try filter.finalize()
            #else
            throw ArchiveError.unsupported("deflate")
            #endif
        } else {
            try copyCompressedBytes(of: entry, from: input, to: emit)
        }

        guard written == entry.uncompressedSize else { throw ArchiveError.malformed(entry.name) }
    }

    private static func copyCompressedBytes(of entry: Entry, from input: FileHandle, to consume: (Data) throws -> Void)
        throws
    {
        var remaining = entry.compressedSize
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: Int(min(Int64(chunkSize), remaining))) ?? Data()
            guard !chunk.isEmpty else { throw ArchiveError.malformed(entry.name) }
            remaining -= Int64(chunk.count)
            try consume(chunk)
        }
    }
}

extension Data {
    fileprivate func uint16(at index: Index) -> UInt16 {
        UInt16(self[index]) | UInt16(self[index + 1]) << 8
    }

    fileprivate func uint32(at index: Index) -> UInt32 {
        UInt32(uint16(at: index)) | UInt32(uint16(at: index + 2)) << 16
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> Substring {
        hasSuffix(suffix) ? dropLast(suffix.count) : self[...]
    }
}
