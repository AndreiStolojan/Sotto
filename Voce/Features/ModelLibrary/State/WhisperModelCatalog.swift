import CryptoKit
import Foundation

/// Pinned downloads for the whisper.cpp models in the model registry.
///
/// URLs point at one immutable Hugging Face commit of `ggerganov/whisper.cpp`, and every file carries
/// the byte size and SHA-256 that the Hugging Face tree API reports for that commit (the Git LFS
/// object ID is the SHA-256 of the file). A download is installed only when both match.
enum WhisperModelCatalog {
    static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    struct Artifact: Equatable, Sendable {
        let fileName: String
        let size: Int64
        let sha256: String

        var url: URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/\(fileName)")!
        }
    }

    struct CoreMLEncoder: Equatable, Sendable {
        let archive: Artifact
        /// Top-level directory inside the archive. It differs from the installed name for large-v2,
        /// whose archive contains `ggml-large-encoder.mlmodelc`.
        let archiveDirectoryName: String
    }

    struct Entry: Equatable, Sendable {
        let model: Artifact
        let coreMLEncoder: CoreMLEncoder?
    }

    enum VerificationError: LocalizedError, Equatable {
        case sizeMismatch(expected: Int64, actual: Int64)
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .sizeMismatch(let expected, let actual):
                return "The downloaded file has \(actual) bytes, expected \(expected)."
            case .checksumMismatch:
                return "The downloaded file does not match its published checksum."
            }
        }
    }

    static func entry(for modelName: String) -> Entry? {
        entries[modelName]
    }

    /// Directory name whisper.cpp looks for next to `<model>.bin`.
    static func installedEncoderDirectoryName(for modelName: String) -> String {
        "\(modelName)-encoder.mlmodelc"
    }

    /// Throws unless the file at `url` has the artifact's exact size and SHA-256.
    static func verify(_ url: URL, matches artifact: Artifact) async throws {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? -1
        guard size == artifact.size else {
            throw VerificationError.sizeMismatch(expected: artifact.size, actual: size)
        }

        // Hashing gigabytes takes seconds, so it runs off the caller's executor and stays cancellable.
        let hashTask = Task.detached(priority: .utility) { try sha256(of: url) }
        let digest = try await withTaskCancellationHandler {
            try await hashTask.value
        } onCancel: {
            hashTask.cancel()
        }
        guard digest == artifact.sha256 else { throw VerificationError.checksumMismatch }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 << 20), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func artifact(_ fileName: String, _ size: Int64, _ sha256: String) -> Artifact {
        Artifact(fileName: fileName, size: size, sha256: sha256)
    }

    private static func encoder(_ name: String, _ size: Int64, _ sha256: String, root: String? = nil)
        -> CoreMLEncoder
    {
        CoreMLEncoder(
            archive: artifact("\(name)-encoder.mlmodelc.zip", size, sha256),
            archiveDirectoryName: root ?? installedEncoderDirectoryName(for: name)
        )
    }

    // Sizes and hashes from https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/<revision>.
    private static let entries: [String: Entry] = [
        "ggml-tiny": Entry(
            model: artifact(
                "ggml-tiny.bin", 77_691_713, "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
            coreMLEncoder: encoder(
                "ggml-tiny", 15_037_446, "c88cbd2648e1f5415092bcf5256add463a0f19943e6938f46e8d4ffdebd47739")),
        "ggml-tiny.en": Entry(
            model: artifact(
                "ggml-tiny.en.bin", 77_704_715, "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"),
            coreMLEncoder: encoder(
                "ggml-tiny.en", 15_034_655, "82b32eef73c94bb0c432a776a047b757d9525c26d84038a15d8798d7c8d1ee58")),
        "ggml-base": Entry(
            model: artifact(
                "ggml-base.bin", 147_951_465, "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
            coreMLEncoder: encoder(
                "ggml-base", 37_922_638, "7e6ab77041942572f239b5b602f8aaa1c3ed29d73e3d8f20abea03a773541089")),
        "ggml-base.en": Entry(
            model: artifact(
                "ggml-base.en.bin", 147_964_211, "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"),
            coreMLEncoder: encoder(
                "ggml-base.en", 37_950_917, "8cf860309e2449e2bdc8be834cf838ab2565747ecc8c0ef914ef5975115e192b")),
        "ggml-large-v2": Entry(
            model: artifact(
                "ggml-large-v2.bin", 3_094_623_691, "9a423fe4d40c82774b6af34115b8b935f34152246eb19e80e376071d3f999487"),
            coreMLEncoder: encoder(
                "ggml-large-v2", 1_174_643_458, "c65d28737f51d09dff3b9da9d26c2ab6f5d82857c9b049ce383d64c2502a5541",
                root: "ggml-large-encoder.mlmodelc")),
        "ggml-large-v3": Entry(
            model: artifact(
                "ggml-large-v3.bin", 3_095_033_483, "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"),
            coreMLEncoder: encoder(
                "ggml-large-v3", 1_175_711_232, "47837be7594a29429ec08620043390c4d6d467f8bd362df09e9390ace76a55a4")),
        "ggml-large-v3-turbo": Entry(
            model: artifact(
                "ggml-large-v3-turbo.bin", 1_624_555_275,
                "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
            coreMLEncoder: encoder(
                "ggml-large-v3-turbo", 1_173_393_014,
                "84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a")),
        "ggml-large-v3-turbo-q5_0": Entry(
            model: artifact(
                "ggml-large-v3-turbo-q5_0.bin", 574_041_195,
                "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
            coreMLEncoder: nil),
    ]
}
