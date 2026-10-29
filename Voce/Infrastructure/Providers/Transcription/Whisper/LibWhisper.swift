import Foundation
import os

#if canImport(whisper)
    import whisper
#else
    #error("Unable to import whisper module. Please check your project configuration.")
#endif

// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer?
    private var prompt: String?
    private var vadModelPath: String?
    private let logger = Logger(subsystem: "ro.andrei.Voce", category: "WhisperContext")

    private init() {}

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        if let context = context {
            whisper_free(context)
        }
    }

    /// Runs one complete transcription in a single actor turn, so concurrent callers sharing this
    /// context cannot interleave settings or read each other's segments. A nil language means
    /// auto-detect, and a nil prompt falls back to the one set with `setPrompt`. Returns nil if
    /// whisper fails.
    func transcribe(samples: [Float], language requestedLanguage: String?, prompt requestedPrompt: String?) -> String? {
        guard let context = context else { return nil }

        let maxThreads = max(1, min(8, cpuCount() - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        let selectedLanguage = requestedLanguage ?? "auto"
        let languageArgument = selectedLanguage == "auto" ? nil : selectedLanguage
        let promptArgument = requestedPrompt ?? prompt

        params.print_realtime = true
        params.print_progress = false
        params.print_timestamps = true
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.temperature = 0.2

        whisper_reset_timings(context)

        // Configure VAD if enabled by user and model is available
        let isVADEnabled = UserDefaults.standard.bool(forKey: "IsVADEnabled")
        let vadModelPath = isVADEnabled ? self.vadModelPath : nil
        if vadModelPath != nil {
            params.vad = true
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.50
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 100
            vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
            vadParams.speech_pad_ms = 30
            vadParams.samples_overlap = 0.1
            params.vad_params = vadParams
        } else {
            params.vad = false
        }

        // C strings are only valid inside these scopes, so whisper_full runs within them.
        let succeeded = withOptionalCString(languageArgument) { languagePointer in
            withOptionalCString(promptArgument) { promptPointer in
                withOptionalCString(vadModelPath) { vadModelPathPointer in
                    params.language = languagePointer
                    params.initial_prompt = promptPointer
                    params.vad_model_path = vadModelPathPointer
                    return samples.withUnsafeBufferPointer { samplesBuffer in
                        whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count)) == 0
                    }
                }
            }
        }

        guard succeeded else {
            logger.error("❌ Failed to run whisper_full. VAD enabled: \(params.vad, privacy: .public)")
            return nil
        }

        var transcription = ""
        for i in 0..<whisper_full_n_segments(context) {
            transcription += String(cString: whisper_full_get_segment_text(context, i))
        }
        return transcription
    }

    static func createContext(path: String) async throws -> WhisperContext {
        let whisperContext = WhisperContext()
        try await whisperContext.initializeModel(path: path)

        // Load VAD model from bundle resources
        let vadModelPath = await VADModelManager.shared.getModelPath()
        await whisperContext.setVADModelPath(vadModelPath)

        return whisperContext
    }

    private func initializeModel(path: String) throws {
        var params = whisper_context_default_params()
        #if targetEnvironment(simulator)
            params.use_gpu = false
            logger.info("Running on the simulator, using CPU")
        #else
            params.flash_attn = true  // Enable flash attention for Metal
            logger.info("Flash attention enabled for Metal")
        #endif

        let context = whisper_init_from_file_with_params(path, params)
        if let context {
            self.context = context
        } else {
            logger.error("❌ Couldn't load model at \(path, privacy: .public)")
            throw VoceEngineError.modelLoadFailed
        }
    }

    private func setVADModelPath(_ path: String?) {
        self.vadModelPath = path
        if path != nil {
            logger.info("VAD model loaded from bundle resources")
        }
    }

    func setPrompt(_ prompt: String?) {
        self.prompt = prompt
    }
}

/// Passes a C string pointer, or nil for a nil string, that is valid only inside `body`.
fileprivate func withOptionalCString<Result>(
    _ string: String?, _ body: (UnsafePointer<CChar>?) -> Result
) -> Result {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}
