import FluidAudio
import Foundation
import os.log
#if VOCE_LOCAL
import CoreML
#endif

/// Runs Parakeet and Nemotron transcription and VAD for batch, prewarm and streaming callers.
///
/// It is an actor so its state is never touched from two threads, and every public operation also
/// runs through `exclusively`. Actor isolation alone is not enough: each `await` inside an operation
/// lets another call in, which could clean up or swap the managers mid-inference, or interleave
/// Nemotron's setLanguage, reset, process and finish sequence with another request.
actor FluidAudioTranscriptionService: TranscriptionService {
    private var asrManager: AsrManager?
    private var unifiedAsrManager: UnifiedAsrManager?
    private var nemotronAsrManager: StreamingNemotronMultilingualAsrManager?
    private var vadManager: VadManager?
    private var activeVersion: AsrModelVersion?
    private var activeNemotronModelName: String?
    private var cachedModels: AsrModels?
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let audioConverter = AudioConverter()
    private let logger = Logger(subsystem: "ro.andrei.Voce", category: "FluidAudioTranscriptionService")

    /// Runs `operation` after earlier operations finish, in call order. Ownership passes directly
    /// to the next waiter, so a newly arriving call cannot slip in between.
    private func exclusively<T>(_ operation: () async throws -> T) async rethrows -> T {
        if isBusy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isBusy = true
        }
        defer {
            if waiters.isEmpty {
                isBusy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        return try await operation()
    }

    private func version(for model: any TranscriptionModel) -> AsrModelVersion {
        FluidAudioModelManager.asrVersion(for: model.name)
    }

    static func languageHint(from selectedLanguage: String?, model: any TranscriptionModel) -> Language? {
        guard model.provider == .fluidAudio else {
            return nil
        }
        return FluidAudioModelManager.languageHint(from: selectedLanguage, for: model.name)
    }

    private func cleanupLoadedManagers() async {
        await unifiedAsrManager?.cleanup()
        await nemotronAsrManager?.cleanup()
        await asrManager?.cleanup()

        unifiedAsrManager = nil
        nemotronAsrManager = nil
        asrManager = nil
        vadManager = nil
        activeVersion = nil
        activeNemotronModelName = nil
    }

    private func ensureModelsLoaded(for version: AsrModelVersion) async throws {
        if asrManager != nil, activeVersion == version {
            return
        }

        // Clean up existing manager but preserve cachedModels for reuse
        await cleanupLoadedManagers()

        let models = try await loadModelsIfNeeded(for: version)

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.activeVersion = version
    }

    private func ensureUnifiedModelsLoaded() async throws {
        if unifiedAsrManager != nil {
            return
        }

        await cleanupLoadedManagers()

        let manager = UnifiedAsrManager(encoderPrecision: FluidAudioModelManager.parakeetUnifiedPrecision)
        try await manager.loadModels(from: FluidAudioModelManager.parakeetUnifiedCacheDirectory())
        self.unifiedAsrManager = manager
    }

    private func ensureNemotronModelsLoaded(named modelName: String) async throws {
        if nemotronAsrManager != nil, activeNemotronModelName == modelName {
            return
        }

        await cleanupLoadedManagers()

        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: FluidAudioModelManager.nemotronCacheDirectory(for: modelName))
        self.nemotronAsrManager = manager
        self.activeNemotronModelName = modelName
    }

    /// Returns cached models or loads them from disk. The streaming provider builds its own manager
    /// from these models.
    func getOrLoadModels(for version: AsrModelVersion) async throws -> AsrModels {
        try await exclusively { try await loadModelsIfNeeded(for: version) }
    }

    private func loadModelsIfNeeded(for version: AsrModelVersion) async throws -> AsrModels {
        if let cached = cachedModels, cached.version == version {
            return cached
        }

        let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)
        let encoderPrecision = FluidAudioModelManager.parakeetEncoderPrecision(for: version)
        guard AsrModels.modelsExist(at: cacheDirectory, version: version, encoderPrecision: encoderPrecision) else {
            throw AsrModelsError.loadingFailed(
                "Parakeet model files are incomplete. Download the model from AI Models."
            )
        }
        #if VOCE_LOCAL
        // Dictation must never repair its model cache through a network download.
        let models = try AsrModels.loadLocal(
            from: cacheDirectory,
            version: version,
            encoderPrecision: encoderPrecision
        )
        #else
        let models = try await AsrModels.load(
            from: cacheDirectory,
            configuration: nil,
            version: version,
            encoderPrecision: encoderPrecision
        )
        #endif
        cachedModels = models
        return models
    }

    func loadModel(for model: FluidAudioModel) async throws {
        try await exclusively {
            try Task.checkCancellation()
            try await loadModelUnlocked(for: model)
        }
    }

    private func loadModelUnlocked(for model: FluidAudioModel) async throws {
        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            // Realtime Nemotron uses a dedicated streaming manager; batch loads lazily in transcribe().
            return
        }

        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            return
        }

        try await ensureModelsLoaded(for: version(for: model))
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        try await exclusively {
            try Task.checkCancellation()
            return try await transcribeUnlocked(audioURL: audioURL, model: model, context: context)
        }
    }

    private func transcribeUnlocked(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> String {
        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            guard let unifiedAsrManager else {
                throw ASRError.notInitialized
            }

            let speechAudio = try await preparedSpeechAudio(from: audioURL)
            guard !speechAudio.isEmpty else { return "" }
            let text = try await unifiedAsrManager.transcribe(speechAudio)
            return text
        }

        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            try await ensureNemotronModelsLoaded(named: model.name)
            guard let nemotronAsrManager else {
                throw ASRError.notInitialized
            }

            let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
                context.language,
                for: model
            )
            let languageHint = FluidAudioModelManager.nemotronLanguageHint(from: compatibleLanguage)
            await nemotronAsrManager.setLanguage(languageHint)
            await nemotronAsrManager.reset()

            var speechAudio = try await preparedSpeechAudio(from: audioURL)
            guard !speechAudio.isEmpty else { return "" }
            let trailingSilenceSamples = 16_000
            let maxSingleChunkSamples = 240_000
            if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
                speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
            }

            _ = try await nemotronAsrManager.process(samples: speechAudio)
            let text = try await nemotronAsrManager.finish()
            return text
        }

        let targetVersion = version(for: model)
        try await ensureModelsLoaded(for: targetVersion)

        guard let asrManager = asrManager else {
            throw ASRError.notInitialized
        }

        let languageHint = Self.languageHint(
            from: context.language,
            model: model
        )
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result: ASRResult
        if UserDefaults.standard.bool(forKey: "IsVADEnabled") {
            let speechAudio = try await preparedSpeechAudio(from: audioURL)
            guard !speechAudio.isEmpty else { return "" }
            result = try await asrManager.transcribe(
                speechAudio,
                decoderState: &decoderState,
                language: languageHint
            )
        } else {
            result = try await asrManager.transcribe(
                audioURL,
                decoderState: &decoderState,
                language: languageHint
            )
        }

        return result.text
    }

    private func loadAudioSamples(from audioURL: URL) throws -> [Float] {
        try audioConverter.resampleAudioFile(audioURL)
    }

    private func preparedSpeechAudio(from audioURL: URL) async throws -> [Float] {
        let samples = try loadAudioSamples(from: audioURL)
        return try await preparedSpeechAudioUnlocked(in: samples)
    }

    func preparedSpeechAudio(in samples: [Float]) async throws -> [Float] {
        try await exclusively { try await preparedSpeechAudioUnlocked(in: samples) }
    }

    private func preparedSpeechAudioUnlocked(in samples: [Float]) async throws -> [Float] {
        guard let segments = try await detectedSpeechAudio(in: samples) else {
            return samples
        }

        var speechAudio = segments.flatMap { $0 }
        guard !speechAudio.isEmpty else { return [] }
        let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
        if speechAudio.count < minimumSamples {
            speechAudio += [Float](repeating: 0, count: minimumSamples - speechAudio.count)
        }
        return speechAudio
    }

    // Streaming callers retain each segment's original position for word timestamps.
    func detectedSpeechSegments(in samples: [Float]) async throws -> [VadSegment]? {
        try await exclusively { try await detectedSpeechSegmentsUnlocked(in: samples) }
    }

    private func detectedSpeechSegmentsUnlocked(in samples: [Float]) async throws -> [VadSegment]? {
        guard UserDefaults.standard.bool(forKey: "IsVADEnabled") else {
            return nil
        }

        do {
            try Task.checkCancellation()
            let manager = try await getOrLoadVadManager()
            let segments = try await manager.segmentSpeech(samples)
            try Task.checkCancellation()
            return segments
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.notice("VAD failed; using full audio: \(error, privacy: .public)")
            return nil
        }
    }

    private func getOrLoadVadManager() async throws -> VadManager {
        if let vadManager { return vadManager }
        #if VOCE_LOCAL
        // VAD is optional. An absent local model immediately falls back to full audio.
        let modelURL = MLModelConfigurationUtils.defaultModelsDirectory(for: .vad)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw VadError.modelLoadingFailed
        }
        let config = VadConfig(defaultThreshold: 0.7)
        let modelConfiguration = MLModelConfigurationUtils.defaultConfiguration(computeUnits: config.computeUnits)
        let model = try MLModel(contentsOf: modelURL, configuration: modelConfiguration)
        let manager = VadManager(config: config, vadModel: model)
        #else
        let manager = try await VadManager(config: VadConfig(defaultThreshold: 0.7))
        #endif
        vadManager = manager
        return manager
    }

    // Nil means VAD is disabled or unavailable; callers preserve the original audio.
    private func detectedSpeechAudio(in samples: [Float]) async throws -> [[Float]]? {
        guard UserDefaults.standard.bool(forKey: "IsVADEnabled") else {
            return nil
        }

        do {
            try Task.checkCancellation()
            let manager = try await getOrLoadVadManager()
            let segments = try await manager.segmentSpeechAudio(samples)
            try Task.checkCancellation()
            return segments
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.notice("VAD failed; using full audio: \(error, privacy: .public)")
            return nil
        }
    }

    /// Releases ASR/VAD resources but preserves cached models for reuse. Waits for a running
    /// transcription instead of releasing its managers underneath it.
    func cleanup() async {
        await exclusively { await cleanupLoadedManagers() }
    }

}
