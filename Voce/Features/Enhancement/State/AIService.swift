import Combine
import Foundation
import LLMkit

/// Local-only enhancement providers. Nothing here talks to a remote API.
enum AIProvider: String, CaseIterable {
    case ollama = "Ollama"
    case localCLI = "Local CLI"

    var defaultModel: String {
        switch self {
        case .ollama:
            return UserDefaults.standard.string(forKey: "ollamaSelectedModel") ?? "mistral"
        case .localCLI:
            return "local-cli"
        }
    }

    var availableModels: [String] { [] }

    /// No local provider accepts a free-form model identifier; Ollama lists its installed models instead.
    var supportsCustomModelID: Bool { false }
}

struct OllamaRefreshResult {
    let models: [OllamaModel]
    let errorMessage: String?
}

/// Tracks the selected local enhancement provider and its model, and brokers requests to it.
class AIService: ObservableObject {
    /// True when the selected provider is ready to enhance text.
    @Published var isAPIKeyValid: Bool = false
    @Published var selectedProvider: AIProvider {
        didSet {
            userDefaults.set(selectedProvider.rawValue, forKey: "selectedAIProvider")
            refreshSelectedProviderAvailability()
            if selectedProvider == .ollama {
                Task {
                    await refreshOllamaAvailability()
                }
            }
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }
    }

    @Published private var selectedModels: [AIProvider: String] = [:]
    private let userDefaults = UserDefaults.standard
    private lazy var ollamaService = OllamaService()
    private lazy var localCLIService = LocalCLIService()
    private var settingsChangeObserver: NSObjectProtocol?

    @Published private(set) var isOllamaRefreshing = false

    var connectedProviders: [AIProvider] {
        AIProvider.allCases.filter { provider in
            switch provider {
            case .ollama:
                return ollamaService.isConnected
            case .localCLI:
                return localCLIService.isConfigured
            }
        }
    }

    var currentModel: String {
        if let selectedModel = selectedModels[selectedProvider],
            !selectedModel.isEmpty,
            selectedProvider == .ollama || availableModels.contains(selectedModel)
        {
            return selectedModel
        }
        return selectedProvider.defaultModel
    }

    func selectedModel(for provider: AIProvider) -> String {
        if let selectedModel = selectedModels[provider], !selectedModel.isEmpty {
            return selectedModel
        }
        return provider.defaultModel
    }

    var availableModels: [String] {
        availableModels(for: selectedProvider)
    }

    var localCLICommandTemplate: String {
        localCLIService.commandTemplate
    }

    var localCLITemplateSelection: LocalCLITemplate {
        localCLIService.selectedTemplate
    }

    var localCLITimeoutSeconds: Double {
        localCLIService.timeoutSeconds
    }

    func availableModels(for provider: AIProvider) -> [String] {
        if provider == .ollama {
            return ollamaService.availableModels.map { $0.name }
        }
        return provider.availableModels
    }

    init() {
        if let savedProvider = userDefaults.string(forKey: "selectedAIProvider"),
            let provider = AIProvider(rawValue: savedProvider)
        {
            self.selectedProvider = provider
        } else {
            self.selectedProvider = .ollama
        }

        refreshSelectedProviderAvailability()
        loadSavedModelSelections()
        initializeAutoLearnSelectionIfNeeded()

        settingsChangeObserver = NotificationCenter.default.addObserver(
            forName: .AppSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.initializeAutoLearnSelectionIfNeeded()
        }
    }

    deinit {
        if let settingsChangeObserver {
            NotificationCenter.default.removeObserver(settingsChangeObserver)
        }
    }

    private func refreshSelectedProviderAvailability() {
        switch selectedProvider {
        case .localCLI:
            isAPIKeyValid = localCLIService.isConfigured
        case .ollama:
            isAPIKeyValid = true
        }
    }

    private func initializeAutoLearnSelectionIfNeeded() {
        guard AutoLearnSettings.selectedProvider == nil else { return }

        let availableProviders = connectedProviders.filter {
            $0 != .ollama || !availableModels(for: $0).isEmpty
        }
        let provider = availableProviders.contains(selectedProvider)
            ? selectedProvider
            : availableProviders.first
        guard let provider else { return }

        AutoLearnSettings.initializeSelectionIfNeeded(
            provider: provider,
            model: initialAutoLearnModel(for: provider)
        )
    }

    private func initialAutoLearnModel(for provider: AIProvider) -> String {
        let selectedModel = selectedModel(for: provider)
        let availableModels = availableModels(for: provider)
        return availableModels.contains(selectedModel)
            ? selectedModel
            : availableModels.first ?? selectedModel
    }

    private func loadSavedModelSelections() {
        for provider in AIProvider.allCases {
            let key = "\(provider.rawValue)SelectedModel"
            if let savedModel = userDefaults.string(forKey: key), !savedModel.isEmpty {
                selectedModels[provider] = savedModel
            }
        }
    }

    func selectModel(_ model: String) {
        selectModel(model, for: selectedProvider)
    }

    func selectModel(_ model: String, for provider: AIProvider) {
        let resolvedInput = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedInput.isEmpty else { return }

        let resolvedModel = resolvedInput
        selectedModels[provider] = resolvedModel
        let key = "\(provider.rawValue)SelectedModel"
        userDefaults.set(resolvedModel, forKey: key)

        if provider == .ollama {
            updateSelectedOllamaModel(resolvedModel)
        }

        objectWillChange.send()
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    func checkOllamaConnection(completion: @escaping (Bool) -> Void) {
        Task { [weak self] in
            guard let self = self else { return }
            _ = await self.refreshOllamaAvailability()
            await MainActor.run {
                completion(self.ollamaService.isConnected)
            }
        }
    }

    /// True when an enabled mode cleans up text with Ollama (a mode without a provider may fall back to it)
    /// or Auto Learn reviews with it.
    static var isOllamaInUse: Bool {
        let modeUsesOllama = ModeManager.shared.configurations.contains {
            $0.isEnabled && $0.isAIEnhancementEnabled
                && ($0.selectedAIProvider ?? AIProvider.ollama.rawValue) == AIProvider.ollama.rawValue
        }
        return modeUsesOllama || (AutoLearnSettings.isEnabled && AutoLearnSettings.selectedProvider == .ollama)
    }

    func refreshOllamaAvailabilityInBackground() {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.refreshOllamaAvailability()
        }
    }

    @MainActor
    @discardableResult
    func refreshOllamaConnectionAndModels() async -> [OllamaModel] {
        let result = await refreshOllamaAvailability()
        return result.models
    }

    @MainActor
    func refreshOllamaAvailability() async -> OllamaRefreshResult {
        guard !isOllamaRefreshing else {
            return OllamaRefreshResult(models: ollamaService.availableModels, errorMessage: nil)
        }

        isOllamaRefreshing = true
        defer {
            isOllamaRefreshing = false
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }

        let result = await ollamaService.refreshConnectionAndModels()
        switch result {
        case .success(let models):
            return OllamaRefreshResult(models: models, errorMessage: nil)
        case .failure(let error):
            return OllamaRefreshResult(models: [], errorMessage: ollamaErrorMessage(for: error))
        }
    }

    private func ollamaErrorMessage(for error: Error) -> String {
        if let llmKitError = error as? LLMKitError {
            return ollamaErrorMessage(for: llmKitError)
        }

        if let localAIError = error as? LocalAIError,
            let errorDescription = localAIError.errorDescription
        {
            return errorDescription
        }

        let nsError = error as NSError
        var details = [nsError.localizedDescription]

        if let failingURL = nsError.userInfo["NSErrorFailingURLKey"] as? URL {
            details.append("URL: \(failingURL.absoluteString)")
        } else if let failingURLString = nsError.userInfo["NSErrorFailingURLStringKey"] as? String {
            details.append("URL: \(failingURLString)")
        }

        details.append("Code: \(nsError.domain) \(nsError.code)")

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            details.append("Underlying: \(underlyingError.localizedDescription)")
            details.append("Underlying code: \(underlyingError.domain) \(underlyingError.code)")
        }

        if let streamErrorCode = nsError.userInfo["_kCFStreamErrorCodeKey"] {
            details.append("Network code: \(streamErrorCode)")
        }

        return details.joined(separator: "\n")
    }

    private func ollamaErrorMessage(for error: LLMKitError) -> String {
        switch error {
        case .httpError(let statusCode, let message):
            let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedMessage.isEmpty else { return "HTTP \(statusCode)" }
            return "HTTP \(statusCode): \(trimmedMessage)"
        default:
            return error.localizedDescription
        }
    }

    func enhanceWithOllama(text: String, systemPrompt: String, model: String? = nil, timeout: TimeInterval = 30)
        async throws -> String
    {
        try await ollamaService.enhance(text, withSystemPrompt: systemPrompt, model: model, timeout: timeout)
    }

    func reviewAutoLearnCandidates(
        payload: String,
        systemPrompt: String,
        provider: AIProvider,
        modelName: String?
    ) async throws -> String {
        try await performChatCompletion(
            provider: provider,
            modelName: modelName,
            messages: [.user(payload)],
            systemPrompt: systemPrompt,
            localUserPrompt: payload,
            timeout: EnhancementRequestSettings.timeout
        )
    }

    func updateOllamaBaseURL(_ newURL: String) {
        ollamaService.baseURL = newURL
        userDefaults.set(newURL, forKey: "ollamaBaseURL")
    }

    func updateSelectedOllamaModel(_ modelName: String) {
        ollamaService.selectedModel = modelName
        userDefaults.set(modelName, forKey: "ollamaSelectedModel")
    }

    func loadLocalCLITemplate(_ template: LocalCLITemplate) {
        localCLIService.loadTemplate(template)
        refreshLocalCLIConfigurationState()
    }

    func updateLocalCLICommandTemplate(_ command: String) {
        localCLIService.commandTemplate = command
        refreshLocalCLIConfigurationState()
    }

    func updateLocalCLITimeoutSeconds(_ timeout: Double) {
        localCLIService.timeoutSeconds = timeout
        refreshLocalCLIConfigurationState()
    }

    func enhanceWithLocalCLI(systemPrompt: String, userPrompt: String) async throws -> String {
        try await localCLIService.enhance(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    private func refreshLocalCLIConfigurationState() {
        if selectedProvider == .localCLI {
            isAPIKeyValid = localCLIService.isConfigured
        }
        objectWillChange.send()
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }
}
