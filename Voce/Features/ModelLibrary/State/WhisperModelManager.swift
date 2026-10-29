import Atomics
import Foundation
import SwiftUI
import os

// MARK: - WhisperModelFile

struct WhisperModelFile: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    var coreMLEncoderURL: URL?  // Path to the unzipped .mlmodelc directory
    var isCoreMLDownloaded: Bool { coreMLEncoderURL != nil }

    var filename: String {
        "\(name).bin"
    }
}

private final class DownloadRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var isCancelled = false

    func install(task: URLSessionDownloadTask, observation: NSKeyValueObservation) -> Bool {
        lock.withLock {
            guard !isCancelled else { return false }
            self.task = task
            self.observation = observation
            return true
        }
    }

    func finish() {
        let observation = lock.withLock {
            let observation = self.observation
            self.observation = nil
            task = nil
            return observation
        }
        observation?.invalidate()
    }

    func cancel() {
        let resources = lock.withLock {
            isCancelled = true
            let resources = (task, observation)
            task = nil
            observation = nil
            return resources
        }
        resources.1?.invalidate()
        resources.0?.cancel()
    }
}

// MARK: - WhisperModelManager

@MainActor
class WhisperModelManager: ObservableObject {
    @Published var availableModels: [WhisperModelFile] = []
    @Published var downloadProgress: [String: Double] = [:]
    @Published var whisperContext: WhisperContext?
    @Published var isModelLoaded = false
    @Published var loadedWhisperModel: WhisperModelFile?
    @Published var isModelLoading = false
    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]
    private var activeProgressKeys: Set<String> = []
    /// Incremented whenever the shared context is dropped, so stale loads can detect it.
    private var contextGeneration = 0
    private static let stagingDirectoryName = ".downloads"

    let modelsDirectory: URL
    let whisperPrompt = WhisperPrompt()

    /// Called when a model is deleted, passing the model name.
    /// TranscriptionModelManager listens to clear currentTranscriptionModel if needed.
    var onModelDeleted: ((String) -> Void)?

    /// Called after a new model is added (downloaded or imported) so
    /// TranscriptionModelManager can rebuild allAvailableModels.
    var onModelsChanged: (() -> Void)?

    let logger = Logger(subsystem: "ro.andrei.Voce", category: "WhisperModelManager")

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    // MARK: - Model Directory Management

    func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: modelsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logError("Error creating models directory", error)
        }
    }

    func loadAvailableModels() {
        if activeDownloadTasks.isEmpty {
            try? FileManager.default.removeItem(
                at: modelsDirectory.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true))
        }

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: modelsDirectory, includingPropertiesForKeys: nil)
            availableModels = fileURLs.compactMap { url in
                guard url.pathExtension == "bin" else { return nil }
                return WhisperModelFile(name: url.deletingPathExtension().lastPathComponent, url: url)
            }
        } catch {
            logError("Error loading available models", error)
        }
    }

    // MARK: - Model Loading

    /// Loads the shared context unless one is already loaded or loading. A load that finishes after
    /// `unloadModel` or `cleanupResources` ran is discarded instead of resurrecting the context.
    func loadModel(_ model: WhisperModelFile) async throws {
        guard whisperContext == nil, !isModelLoading else { return }

        isModelLoading = true
        defer { isModelLoading = false }
        let generation = contextGeneration

        let context: WhisperContext
        do {
            context = try await WhisperContext.createContext(path: model.url.path)
            let currentPrompt =
                UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? whisperPrompt.transcriptionPrompt
            await context.setPrompt(currentPrompt)
        } catch {
            throw VoceEngineError.modelLoadFailed
        }

        guard generation == contextGeneration, whisperContext == nil else { return }
        whisperContext = context
        isModelLoaded = true
        loadedWhisperModel = model
    }

    // MARK: - Model Download & Management

    /// Downloads `url` into `directory` and returns the file, without reading it into memory.
    /// Progress is published under `progressKey` only while this download is active.
    private func downloadFile(from url: URL, into directory: URL, progressKey: String) async throws -> URL {
        let destinationURL = directory.appendingPathComponent(UUID().uuidString)
        let requestState = DownloadRequestState()
        activeProgressKeys.insert(progressKey)
        defer { activeProgressKeys.remove(progressKey) }

        return try await withTaskCancellationHandler(
            operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<URL, Error>) in
                    let finished = ManagedAtomic(false)

                    func finishOnce(_ result: Result<URL, Error>) {
                        requestState.finish()
                        if finished.exchange(true, ordering: .acquiring) == false {
                            continuation.resume(with: result)
                        }
                    }

                    let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                        if let error {
                            let reportedError: Error = (error as? URLError)?.code == .cancelled
                                ? CancellationError()
                                : error
                            finishOnce(.failure(reportedError))
                            return
                        }

                        guard let httpResponse = response as? HTTPURLResponse,
                            (200...299).contains(httpResponse.statusCode),
                            let tempURL
                        else {
                            finishOnce(.failure(URLError(.badServerResponse)))
                            return
                        }

                        // URLSession deletes tempURL when this handler returns, so move it now.
                        do {
                            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                            finishOnce(.success(destinationURL))
                        } catch {
                            finishOnce(.failure(error))
                        }
                    }

                    var lastUpdateTime = Date()
                    var lastProgressValue: Double = 0

                    let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                        let currentTime = Date()
                        let timeSinceLastUpdate = currentTime.timeIntervalSince(lastUpdateTime)
                        let currentProgress = round(progress.fractionCompleted * 100) / 100

                        if timeSinceLastUpdate >= 0.5 && abs(currentProgress - lastProgressValue) >= 0.01 {
                            lastUpdateTime = currentTime
                            lastProgressValue = currentProgress

                            DispatchQueue.main.async {
                                // A late update must not re-create a key the finished download removed.
                                guard self.activeProgressKeys.contains(progressKey) else { return }
                                self.downloadProgress[progressKey] = currentProgress
                            }
                        }
                    }

                    guard requestState.install(task: task, observation: observation) else {
                        observation.invalidate()
                        task.cancel()
                        finishOnce(.failure(CancellationError()))
                        return
                    }

                    task.resume()
                }
            },
            onCancel: {
                requestState.cancel()
            }
        )
    }

    func downloadModel(_ model: WhisperModel) async {
        await performModelDownload(model)
    }

    func startDownload(_ model: WhisperModel) {
        guard activeDownloadTasks[model.name] == nil else { return }
        downloadProgress[model.name + "_main"] = 0
        activeDownloadTasks[model.name] = Task { [weak self] in
            guard let self else { return }
            await self.downloadModel(model)
            self.activeDownloadTasks[model.name] = nil
        }
    }

    func cancelDownload(_ model: WhisperModel) {
        activeDownloadTasks[model.name]?.cancel()
    }

    /// Downloads the main model, then the optional Core ML encoder, from the pinned catalog. Files land
    /// in a private staging directory and must match their published size and SHA-256 first, so a
    /// cancelled, failed or tampered download never replaces installed files. The main model works on
    /// its own, so it stays listed when only the Core ML encoder fails.
    private func performModelDownload(_ model: WhisperModel) async {
        let stagingDirectory = modelsDirectory
            .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDirectory)
            downloadProgress.removeValue(forKey: model.name + "_main")
            downloadProgress.removeValue(forKey: model.name + "_coreml")
        }

        var whisperModel: WhisperModelFile
        let catalogEntry = WhisperModelCatalog.entry(for: model.name)
        do {
            guard let catalogEntry else { throw URLError(.unsupportedURL) }
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            whisperModel = try await downloadMainModel(
                model, artifact: catalogEntry.model, stagingDirectory: stagingDirectory)
        } catch is CancellationError {
            return
        } catch {
            logError("Model download failed: \(model.name)", error)
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "%@ download failed"), model.displayName),
                type: .error
            )
            return
        }

        if let encoder = catalogEntry?.coreMLEncoder {
            do {
                try Task.checkCancellation()
                whisperModel.coreMLEncoderURL = try await downloadCoreMLEncoder(
                    for: whisperModel,
                    encoder: encoder,
                    stagingDirectory: stagingDirectory
                )
            } catch is CancellationError {
                // Keep the committed main model; the Core ML encoder is optional.
            } catch {
                logError("Core ML encoder install failed: \(model.name)", error)
                NotificationManager.shared.showNotification(
                    title: String(
                        format: String(localized: "Core ML download failed for %@. The model still works without it."),
                        model.displayName),
                    type: .warning
                )
            }
        }

        availableModels.removeAll { $0.name == whisperModel.name }
        availableModels.append(whisperModel)
        onModelsChanged?()

        if !Task.isCancelled, shouldWarmup(model) {
            WhisperModelWarmupCoordinator.shared.scheduleWarmup(for: model, whisperModelManager: self)
        }
    }

    private func downloadMainModel(
        _ model: WhisperModel, artifact: WhisperModelCatalog.Artifact, stagingDirectory: URL
    ) async throws -> WhisperModelFile {
        let downloadedURL = try await downloadFile(
            from: artifact.url, into: stagingDirectory, progressKey: model.name + "_main")
        try await WhisperModelCatalog.verify(downloadedURL, matches: artifact)
        try Task.checkCancellation()

        let destinationURL = modelsDirectory.appendingPathComponent(model.filename)
        try WhisperCoreMLArchive.replaceItem(
            at: destinationURL, with: downloadedURL, backupDirectory: stagingDirectory)
        return WhisperModelFile(name: model.name, url: destinationURL)
    }

    private func downloadCoreMLEncoder(
        for model: WhisperModelFile,
        encoder: WhisperModelCatalog.CoreMLEncoder,
        stagingDirectory: URL
    ) async throws -> URL {
        let zipURL = try await downloadFile(
            from: encoder.archive.url, into: stagingDirectory, progressKey: model.name + "_coreml")
        try await WhisperModelCatalog.verify(zipURL, matches: encoder.archive)
        try Task.checkCancellation()

        return try await WhisperCoreMLArchive.install(
            zipURL: zipURL,
            archiveDirectoryName: encoder.archiveDirectoryName,
            installedName: WhisperModelCatalog.installedEncoderDirectoryName(for: model.name),
            stagingDirectory: stagingDirectory,
            destinationDirectory: modelsDirectory
        )
    }

    private func shouldWarmup(_ model: WhisperModel) -> Bool {
        !model.name.contains("q5") && !model.name.contains("q8")
    }

    func deleteModel(_ model: WhisperModelFile) async {
        do {
            try FileManager.default.removeItem(at: model.url)
            if loadedWhisperModel?.name == model.name {
                unloadModel()
            }

            if let coreMLURL = model.coreMLEncoderURL {
                try? FileManager.default.removeItem(at: coreMLURL)
            } else {
                let coreMLDir = modelsDirectory.appendingPathComponent("\(model.name)-encoder.mlmodelc")
                if FileManager.default.fileExists(atPath: coreMLDir.path) {
                    try? FileManager.default.removeItem(at: coreMLDir)
                }
            }

            availableModels.removeAll { $0.id == model.id }

            // Notify TranscriptionModelManager to clear currentTranscriptionModel if it matches
            onModelDeleted?(model.name)
        } catch {
            logError("Error deleting model: \(model.name)", error)
        }
    }

    /// Drops the shared context. whisper.cpp memory is freed once in-flight transcriptions that
    /// still hold the context finish, instead of being released underneath them.
    func unloadModel() {
        contextGeneration += 1
        whisperContext = nil
        isModelLoaded = false
    }

    func clearDownloadedModels() async {
        for model in availableModels {
            do {
                try FileManager.default.removeItem(at: model.url)
            } catch {
                logError("Error deleting model during cleanup", error)
            }
        }
        availableModels.removeAll()
    }

    // MARK: - Resource Management

    /// Releases the WhisperContext and resets model-loaded state.
    /// Does NOT call serviceRegistry.cleanup() — that is VoceEngine's responsibility.
    func cleanupResources() async {
        logger.notice("WhisperModelManager.cleanupResources: releasing whisper context")
        unloadModel()
        logger.notice("WhisperModelManager.cleanupResources: completed")
    }

    // MARK: - Import Local Model

    func importWhisperModel(from sourceURL: URL) async {
        guard sourceURL.pathExtension.lowercased() == "bin" else { return }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let destinationURL = modelsDirectory.appendingPathComponent("\(baseName).bin")

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "A model named %@.bin already exists"), baseName),
                type: .warning,
                duration: 4.0
            )
            return
        }

        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let newWhisperModel = WhisperModelFile(name: baseName, url: destinationURL)
            availableModels.append(newWhisperModel)

            onModelsChanged?()

            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Imported %@"), destinationURL.lastPathComponent),
                type: .success,
                duration: 3.0
            )
        } catch {
            logError("Failed to import local model", error)
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Failed to import model: %@"), error.localizedDescription),
                type: .error,
                duration: 5.0
            )
        }
    }

    // MARK: - Helpers

    private func logError(_ message: String, _ error: Error) {
        logger.error("❌ \(message, privacy: .public): \(error, privacy: .public)")
    }
}

// MARK: - WhisperModelProvider

extension WhisperModelManager: WhisperModelProvider {}

// MARK: - Download Progress View

struct DownloadProgressView: View {
    let modelName: String
    let downloadProgress: [String: Double]
    var isOptimizing = false

    @Environment(\.colorScheme) private var colorScheme

    private var mainProgress: Double {
        downloadProgress[modelName + "_main"] ?? 0
    }

    private var coreMLProgress: Double {
        supportsCoreML ? (downloadProgress[modelName + "_coreml"] ?? 0) : 0
    }

    private var supportsCoreML: Bool {
        !modelName.contains("q5") && !modelName.contains("q8")
    }

    private var totalProgress: Double {
        if isOptimizing {
            return 1
        }

        return supportsCoreML ? (mainProgress * 0.5) + (coreMLProgress * 0.5) : mainProgress
    }

    private var downloadPhase: String {
        if isOptimizing {
            return String(localized: "Optimizing model for your device")
        }

        if supportsCoreML && downloadProgress[modelName + "_coreml"] != nil {
            return String(format: String(localized: "Downloading Core ML Model for %@"), modelName)
        }
        return String(format: String(localized: "Downloading %@ Model"), modelName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(downloadPhase)
                    .lineLimit(1)

                Spacer()

                Text(totalProgress, format: .percent.precision(.fractionLength(0)))
                    .fontDesign(.monospaced)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color(.secondaryLabelColor))

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppTheme.Border.control.opacity(0.3))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppTheme.Accent.primary)
                        .frame(width: max(0, min(geometry.size.width * totalProgress, geometry.size.width)), height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
    }
}
