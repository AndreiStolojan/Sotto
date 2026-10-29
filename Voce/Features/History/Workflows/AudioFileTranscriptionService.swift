import AVFoundation
import Foundation
import SwiftData
import SwiftUI
import os

struct AudioRetranscriptionResult {
    let transcription: Transcription
    let enhancementFailure: String?
}

/// Retranscribes a saved recording into a new History entry with its own copy of the audio.
@MainActor
class AudioTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var currentError: TranscriptionError?

    private let modelContext: ModelContext
    private let enhancementService: AIEnhancementService?
    private let logger = Logger(subsystem: "ro.andrei.Voce", category: "AudioTranscriptionService")
    private let serviceRegistry: TranscriptionServiceRegistry
    /// True when this service created its registry, so it must release the models it loaded.
    /// A caller's registry, such as the engine's, stays loaded for the caller to manage.
    private let ownsServiceRegistry: Bool

    enum TranscriptionError: Error {
        case noAudioFile
        case transcriptionFailed
        case modelNotLoaded
        case invalidAudioFormat
    }

    init(modelContext: ModelContext, engine: VoceEngine) {
        self.modelContext = modelContext
        self.enhancementService = engine.enhancementService
        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager, modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: modelContext)
        self.ownsServiceRegistry = true
    }

    init(
        modelContext: ModelContext, serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.enhancementService = enhancementService
        self.serviceRegistry = serviceRegistry
        self.ownsServiceRegistry = false
    }

    /// Returns only after the new transcription is saved. Any failure, including cancellation or a
    /// failed save, throws and removes the audio copy made for it.
    func retranscribeAudio(from url: URL, using model: any TranscriptionModel, mode: ModeConfig? = nil) async throws
        -> AudioRetranscriptionResult
    {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudioFile
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let result = try await performRetranscription(from: url, using: model, mode: mode)
            await releaseOwnedModels()
            return result
        } catch {
            await releaseOwnedModels()
            if !(error is CancellationError) {
                logger.error("❌ Transcription failed: \(error, privacy: .public)")
                currentError = .transcriptionFailed
            }
            throw error
        }
    }

    private func releaseOwnedModels() async {
        guard ownsServiceRegistry else { return }
        await serviceRegistry.cleanup()
    }

    private func performRetranscription(
        from url: URL, using model: any TranscriptionModel, mode: ModeConfig?
    ) async throws -> AudioRetranscriptionResult {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
        let language = TranscriptionLanguageSupport.validLanguageOrFallback(
            mode?.selectedLanguage,
            for: model,
            realtimeEnabled: mode?.isRealtimeTranscriptionEnabled
        )
        let requestContext = TranscriptionRequestContext(
            language: language,
            prompt: model.provider == .whisper ? WhisperPrompt.resolvedPrompt(for: language) : nil
        )
        let modeName = (mode?.isEnabled == true) ? mode?.name : nil
        let modeEmoji = (mode?.isEnabled == true) ? mode?.icon.value : nil

        let transcriptionStart = Date()
        var text = try await serviceRegistry.transcribe(audioURL: url, model: model, context: requestContext)
        let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
        text = TranscriptionOutputFilter.filter(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formattingConfiguration = ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode)

        if formattingConfiguration.isTextFormattingEnabled {
            text = ParagraphFormatter.format(text)
        }

        text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
        let originalText = text

        let audioAsset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
        try Task.checkCancellation()

        let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0
        ]
        .appendingPathComponent(AppStorageNamespace.applicationSupportDirectoryName)
        .appendingPathComponent("Recordings")
        let permanentURL = recordingsDirectory.appendingPathComponent("retranscribed_\(UUID().uuidString).wav")

        do {
            try FileManager.default.copyItem(at: url, to: permanentURL)
        } catch {
            logger.error("❌ Failed to create permanent copy of audio: \(error, privacy: .public)")
            throw error
        }

        do {
            let (transcription, enhancementFailure) = try await makeTranscription(
                text: originalText,
                duration: duration,
                audioURL: permanentURL,
                model: model,
                mode: mode,
                transcriptionDuration: transcriptionDuration,
                modeName: modeName,
                modeEmoji: modeEmoji
            )
            try Task.checkCancellation()
            try save(transcription)
            return AudioRetranscriptionResult(transcription: transcription, enhancementFailure: enhancementFailure)
        } catch {
            try? FileManager.default.removeItem(at: permanentURL)
            throw error
        }
    }

    /// Builds the record, enhanced when the mode asks for it. An enhancement failure is kept on the
    /// record and returned; cancellation is not a failure and propagates.
    private func makeTranscription(
        text: String,
        duration: TimeInterval,
        audioURL: URL,
        model: any TranscriptionModel,
        mode: ModeConfig?,
        transcriptionDuration: TimeInterval,
        modeName: String?,
        modeEmoji: String?
    ) async throws -> (Transcription, enhancementFailure: String?) {
        let enhancementConfiguration =
            enhancementService
            .flatMap { service in
                service.getAIService().map { aiService in
                    ModeRuntimeResolver.currentEnhancementConfiguration(
                        mode: mode,
                        enhancementService: service,
                        aiService: aiService
                    )
                }
            }

        guard let enhancementService,
            let enhancementConfiguration,
            enhancementConfiguration.isEnabled,
            enhancementService.isConfigured(for: enhancementConfiguration)
        else {
            let transcription = Transcription(
                text: text,
                duration: duration,
                audioFileURL: audioURL.absoluteString,
                transcriptionModelName: model.displayName,
                promptName: nil,
                transcriptionDuration: transcriptionDuration,
                modeName: modeName,
                modeEmoji: modeEmoji
            )
            return (transcription, nil)
        }

        let enhancementModelName = enhancementConfiguration.modelName ?? enhancementConfiguration.provider?.defaultModel
        do {
            let enhancementResult = try await enhancementService.enhance(text, configuration: enhancementConfiguration)
            let transcription = Transcription(
                text: text,
                duration: duration,
                enhancedText: enhancementResult.text,
                audioFileURL: audioURL.absoluteString,
                transcriptionModelName: model.displayName,
                aiEnhancementModelName: enhancementModelName,
                promptName: enhancementResult.promptName ?? enhancementConfiguration.prompt?.title,
                transcriptionDuration: transcriptionDuration,
                enhancementDuration: enhancementResult.duration,
                aiRequestSystemMessage: enhancementResult.systemMessage,
                aiRequestUserMessage: enhancementResult.userMessage,
                modeName: modeName,
                modeEmoji: modeEmoji
            )
            return (transcription, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failureDescription = EnhancementFailureFormatter.description(for: error)
            let transcription = Transcription(
                text: text,
                duration: duration,
                enhancedText: EnhancementFailureFormatter.message(description: failureDescription),
                audioFileURL: audioURL.absoluteString,
                transcriptionModelName: model.displayName,
                aiEnhancementModelName: enhancementModelName,
                promptName: enhancementConfiguration.prompt?.title,
                transcriptionDuration: transcriptionDuration,
                modeName: modeName,
                modeEmoji: modeEmoji
            )
            return (transcription, failureDescription)
        }
    }

    /// Inserts and saves the record, then announces it. A failed save removes the insert so a later
    /// save cannot persist a record whose audio copy was deleted.
    private func save(_ transcription: Transcription) throws {
        modelContext.insert(transcription)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(transcription)
            logger.error("❌ Failed to save transcription: \(error, privacy: .public)")
            throw error
        }
        NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
    }
}
