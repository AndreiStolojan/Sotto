import Foundation
import os

/// Monotonic timings for one dictation: stop request → audio finalized → transcribed
/// → enhanced (only with AI enhancement on) → text inserted. Emits one log line per
/// dictation, never the transcript. Read it with:
/// `/usr/bin/log stream --predicate 'subsystem == "ro.andrei.Voce" AND category == "DictationLatency"'`
@MainActor
final class DictationLatencyTrace {
    private static let logger = Logger(subsystem: "ro.andrei.Voce", category: "DictationLatency")
    private static var hasTranscribedSinceLaunch = false

    private let stopRequested = ContinuousClock.now
    private var audioFinalized: ContinuousClock.Instant?
    private var transcribed: ContinuousClock.Instant?
    private var enhanced: ContinuousClock.Instant?
    private var isFirstSinceLaunch = false
    private var engine = "-"
    private var model = "-"
    var audioDuration: TimeInterval = 0

    func markAudioFinalized() {
        audioFinalized = .now
    }

    func markTranscribed(with model: any TranscriptionModel) {
        transcribed = .now
        isFirstSinceLaunch = !Self.hasTranscribedSinceLaunch
        Self.hasTranscribedSinceLaunch = true
        engine = model.provider.rawValue
        self.model = model.displayName
    }

    func markEnhanced() {
        enhanced = .now
    }

    /// Logs the line. `inserted` is false when transcription failed or no paste command was posted.
    func finish(inserted: Bool) {
        let end = ContinuousClock.now
        let beforeInsert = enhanced ?? transcribed ?? audioFinalized ?? stopRequested

        Self.logger.notice(
            "dictation first=\(self.isFirstSinceLaunch, privacy: .public) engine=\(self.engine, privacy: .public) model=\(self.model, privacy: .public) audio=\(Self.seconds(self.audioDuration), privacy: .public)s finalize=\(Self.segment(self.stopRequested, self.audioFinalized), privacy: .public) transcribe=\(Self.segment(self.audioFinalized, self.transcribed), privacy: .public) enhance=\(Self.segment(self.transcribed, self.enhanced), privacy: .public) insert=\(Self.segment(beforeInsert, end), privacy: .public) total=\(Self.segment(self.stopRequested, end), privacy: .public) inserted=\(inserted, privacy: .public)"
        )
    }

    private static func segment(_ from: ContinuousClock.Instant?, _ to: ContinuousClock.Instant?) -> String {
        guard let from, let to else { return "-" }
        let components = (to - from).components
        return seconds(Double(components.seconds) + Double(components.attoseconds) / 1e18) + "s"
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
