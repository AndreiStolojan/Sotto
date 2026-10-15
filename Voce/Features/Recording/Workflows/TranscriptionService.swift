import Foundation

struct TranscriptionRequestContext {
    let language: String?
    let prompt: String?

    static var currentDefaults: TranscriptionRequestContext {
        let language = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "auto"
        return TranscriptionRequestContext(
            language: language,
            prompt: WhisperPrompt.resolvedPrompt(for: language)
        )
    }

    /// Narrows the context to what the model accepts. The language is validated against the model,
    /// so the global `SelectedLanguage` (which may hold Parakeet's `latin` key) never reaches
    /// whisper.cpp as an unknown language. Only Whisper uses the prompt, re-resolved if the
    /// language had to change.
    func scoped(to model: any TranscriptionModel) -> TranscriptionRequestContext {
        let validLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(language, for: model)
        guard model.provider == .whisper else {
            return TranscriptionRequestContext(language: validLanguage, prompt: nil)
        }
        guard validLanguage != language else { return self }

        return TranscriptionRequestContext(
            language: validLanguage, prompt: WhisperPrompt.resolvedPrompt(for: validLanguage))
    }
}

/// A protocol defining the interface for a transcription service.
/// This allows for a unified way to handle both local and cloud-based transcription models.
protocol TranscriptionService {
    /// Transcribes the audio from a given file URL.
    ///
    /// - Parameters:
    ///   - audioURL: The URL of the audio file to transcribe.
    ///   - model: The `TranscriptionModel` to use for transcription. This provides context about the provider (local, OpenAI, etc.).
    /// - Returns: The transcribed text as a `String`.
    /// - Throws: An error if the transcription fails.
    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
}

extension TranscriptionService {
    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        let context = TranscriptionRequestContext.currentDefaults.scoped(to: model)
        return try await transcribe(audioURL: audioURL, model: model, context: context)
    }
}
