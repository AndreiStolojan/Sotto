import AppKit
import Foundation
import SwiftData

/// Exports selected History entries as CSV; the header is a contract with `scripts/benchmark.py`.
class VoceCSVExportService {

    func exportTranscriptionsToCSV(transcriptions: [Transcription]) {
        let csvString = generateCSV(for: transcriptions)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.nameFieldStringValue = "Voce-transcription.csv"

        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                do {
                    try csvString.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    print("Error writing CSV file: \(error)")
                }
            }
        }
    }

    private func generateCSV(for transcriptions: [Transcription]) -> String {
        var csvString =
            "Original Transcript,Enhanced Transcript,Enhancement Model,Prompt Name,Transcription Model,Mode,Enhancement Time,Transcription Time,Timestamp,Duration\n"

        for transcription in transcriptions {
            let originalText = CSVField.escape(transcription.text)
            let enhancedText = CSVField.escape(transcription.enhancedText ?? "")
            let enhancementModel = CSVField.escape(transcription.aiEnhancementModelName ?? "")
            let promptName = CSVField.escape(transcription.promptName ?? "")
            let transcriptionModel = CSVField.escape(transcription.transcriptionModelName ?? "")
            let mode = CSVField.escape(transcription.modeName ?? "")
            let enhancementTime = transcription.enhancementDuration ?? 0
            let transcriptionTime = transcription.transcriptionDuration ?? 0
            let timestamp = transcription.timestamp.ISO8601Format()
            let duration = transcription.duration

            let row =
                "\(originalText),\(enhancedText),\(enhancementModel),\(promptName),\(transcriptionModel),\(mode),\(enhancementTime),\(transcriptionTime),\(timestamp),\(duration)\n"
            csvString.append(row)
        }

        return csvString
    }
}
