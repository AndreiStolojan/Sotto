import FluidAudio
import Foundation
import os

/// Transcribes with whisper.cpp. Reuses the model provider's loaded context when it matches the
/// requested model; otherwise loads a private context that lives only for this request.
class WhisperTranscriptionService: TranscriptionService {
    private let logger = Logger(subsystem: "ro.andrei.Voce", category: "WhisperTranscriptionService")
    private let modelsDirectory: URL
    private weak var modelProvider: (any WhisperModelProvider)?
    private let audioConverter = AudioConverter()

    init(modelsDirectory: URL, modelProvider: (any WhisperModelProvider)? = nil) {
        self.modelsDirectory = modelsDirectory
        self.modelProvider = modelProvider
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        guard model.provider == .whisper else {
            throw VoceEngineError.modelLoadFailed
        }

        logger.notice("Initiating local transcription for model: \(model.displayName, privacy: .public)")

        let whisperContext = try await resolveContext(for: model)

        // Decode and resample any supported file to 16 kHz mono Float32 instead of assuming a
        // 44-byte PCM16 WAV header. Core Audio WAV files can carry extra chunks before the samples.
        let samples = try audioConverter.resampleAudioFile(audioURL)
        try Task.checkCancellation()

        guard
            let text = await whisperContext.transcribe(
                samples: samples,
                language: context.language,
                prompt: context.prompt ?? ""
            )
        else {
            logger.error("❌ Core transcription engine failed (whisper_full).")
            throw VoceEngineError.whisperCoreFailed
        }

        logger.notice("Whisper transcription completed successfully.")
        return text
    }

    /// The shared context stays owned by the model provider. A private context is freed when the
    /// last reference to it goes away at the end of the request.
    private func resolveContext(for model: any TranscriptionModel) async throws -> WhisperContext {
        if let provider = modelProvider,
            await provider.isModelLoaded,
            let loadedContext = await provider.whisperContext,
            await provider.loadedWhisperModel?.name == model.name
        {
            logger.notice("Using already loaded model: \(model.name, privacy: .public)")
            return loadedContext
        }

        // Resolve the on-disk URL using the provider's availableModels (covers imports)
        let resolvedURL: URL? = await modelProvider?.availableModels.first(where: { $0.name == model.name })?.url
        guard let modelURL = resolvedURL, FileManager.default.fileExists(atPath: modelURL.path) else {
            logger.error("❌ Model file not found for: \(model.name, privacy: .public)")
            throw VoceEngineError.modelLoadFailed
        }

        logger.notice("Loading model: \(model.name, privacy: .public)")
        do {
            return try await WhisperContext.createContext(path: modelURL.path)
        } catch {
            logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error, privacy: .public)")
            throw VoceEngineError.modelLoadFailed
        }
    }
}
