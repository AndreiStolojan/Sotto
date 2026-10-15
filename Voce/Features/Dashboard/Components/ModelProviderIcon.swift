import Foundation
import SwiftUI

struct ModelProviderIcon: View {
    let modelName: String
    let kind: ModelInsightKind
    var size: CGFloat = 24

    var body: some View {
        let identity = ModelProviderIdentity.resolve(modelName: modelName, kind: kind)

        ProviderBrandIcon(
            systemImage: identity.systemImage,
            isSelected: false,
            size: size,
            iconSize: max(12, size * 0.54)
        )
        .help(identity.providerName)
    }
}

/// Maps a stored model name back to the local provider that produced it.
private struct ModelProviderIdentity {
    let providerName: String
    let systemImage: String

    static func resolve(modelName: String, kind: ModelInsightKind) -> ModelProviderIdentity {
        switch kind {
        case .transcription:
            return resolveTranscription(modelName)
        case .enhancement:
            return resolveEnhancement(modelName)
        }
    }

    private static func resolveTranscription(_ modelName: String) -> ModelProviderIdentity {
        let trimmedName = normalized(modelName)

        if let model = TranscriptionModelRegistry.models.first(where: { model in
            namesMatch(model.displayName, trimmedName) || namesMatch(model.name, trimmedName)
        }) {
            if let transcribeCppModel = model as? TranscribeCppModel {
                return transcribeCppIdentity(publisher: transcribeCppModel.publisher)
            }
            return identity(for: model.provider)
        }

        if trimmedName.localizedCaseInsensitiveContains("parakeet")
            || trimmedName.localizedCaseInsensitiveContains("nemotron")
        {
            return identity(for: .fluidAudio)
        }

        if trimmedName.localizedCaseInsensitiveContains("cohere") {
            return transcribeCppIdentity(publisher: "Cohere")
        }

        if trimmedName.localizedCaseInsensitiveContains("apple") {
            return identity(for: .nativeApple)
        }

        let identifierTokens = trimmedName.lowercased().split { !$0.isLetter && !$0.isNumber }
        if identifierTokens.contains("whisper") {
            return identity(for: .whisper)
        }

        return ModelProviderIdentity(
            providerName: String(localized: "Transcription Model"), systemImage: "captions.bubble.fill")
    }

    private static func resolveEnhancement(_ modelName: String) -> ModelProviderIdentity {
        let trimmedName = normalized(modelName)

        let matchingProviders = AIProvider.allCases.filter { provider in
            providerMatches(provider, modelName: trimmedName)
        }

        if matchingProviders.count == 1, let provider = matchingProviders.first {
            return identity(for: provider)
        }

        return ModelProviderIdentity(providerName: String(localized: "Enhancement Model"), systemImage: "cpu")
    }

    private static func identity(for provider: ModelProvider) -> ModelProviderIdentity {
        switch provider {
        case .whisper:
            return ModelProviderIdentity(providerName: "Whisper", systemImage: "captions.bubble.fill")
        case .fluidAudio:
            return ModelProviderIdentity(providerName: "Parakeet", systemImage: "waveform")
        case .transcribeCpp:
            return ModelProviderIdentity(providerName: "On-Device", systemImage: "waveform.badge.magnifyingglass")
        case .nativeApple:
            return ModelProviderIdentity(providerName: "Apple Speech", systemImage: "apple.logo")
        }
    }

    private static func transcribeCppIdentity(publisher: String) -> ModelProviderIdentity {
        ModelProviderIdentity(providerName: publisher, systemImage: "waveform.badge.magnifyingglass")
    }

    private static func identity(for provider: AIProvider) -> ModelProviderIdentity {
        let systemImage: String
        switch provider {
        case .ollama:
            systemImage = "server.rack"
        case .localCLI:
            systemImage = "terminal"
        }
        return ModelProviderIdentity(providerName: provider.rawValue, systemImage: systemImage)
    }

    private static func providerMatches(_ provider: AIProvider, modelName: String) -> Bool {
        if namesMatch(provider.defaultModel, modelName) {
            return true
        }

        return provider.availableModels.contains { availableModel in
            namesMatch(availableModel, modelName)
        }
    }

    private static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs).caseInsensitiveCompare(normalized(rhs)) == .orderedSame
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
