import AVFoundation
import CoreGraphics
import Foundation

/// Fast checks against production code, independent of microphone permissions and ASR models.
@main
struct CoreTests {
    private static var checks = 0
    private static var failures = 0

    static func main() {
        checkAudioConversion()
        checkSessionPolicy()
        checkTranscripts()
        checkLanguagePolicy()
        checkNotchProtocol()
        checkUpdateCheck()
        print("\(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if condition() {
            print("PASS: \(description)")
        } else {
            failures += 1
            fputs("FAIL: \(description)\n", stderr)
        }
    }

    private static func checkAudioConversion() {
        // Signed 16-bit little-endian samples: minimum, zero, maximum, positive and negative halves.
        let data = Data([0x00, 0x80, 0x00, 0x00, 0xff, 0x7f, 0x00, 0x40, 0x00, 0xc0])
        let samples = PCMAudioConverter.float32Samples(fromPCM16Data: data)
        expect(samples.count == 5, "PCM conversion preserves the sample count")
        expect(samples.prefix(3).elementsEqual([-1, 0, 1]), "PCM conversion clamps signed endpoints and preserves silence")
        expect(samples.count == 5 && abs(samples[3] - 0.5) < 0.0001 && abs(samples[4] + 0.5) < 0.0001,
               "PCM conversion reads little-endian signed values")
        expect(PCMAudioConverter.float32Samples(fromPCM16Data: Data()).isEmpty,
               "Empty audio produces no samples")
        expect(PCMAudioConverter.pcmBuffer(fromPCM16Data: Data()) == nil,
               "Empty audio cannot create an inference buffer")

        guard let buffer = PCMAudioConverter.pcmBuffer(fromPCM16Data: data) else {
            expect(false, "Nonempty audio creates an inference buffer")
            return
        }
        expect(buffer.format.sampleRate == 16_000 && buffer.format.channelCount == 1
               && buffer.format.commonFormat == .pcmFormatFloat32,
               "Inference audio uses 16 kHz mono Float32")
        expect(buffer.frameLength == 5 && buffer.floatChannelData.map {
            Array(UnsafeBufferPointer(start: $0[0], count: Int(buffer.frameLength))) == samples
        } == true, "Inference buffer contains every converted sample")
    }

    private static func checkSessionPolicy() {
        let onConsole = kCGSessionOnConsoleKey as String
        let loggedIn = kCGSessionLoginDoneKey as String
        let locked = "CGSSessionScreenIsLocked"
        let active: [String: Any] = [onConsole: true, loggedIn: true, locked: false]

        expect(UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: active),
               "An unlocked console session accepts shortcuts")
        expect(!UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: [onConsole: true, loggedIn: true, locked: true]),
               "A locked session blocks shortcuts")
        expect(!UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: [onConsole: false, loggedIn: true]),
               "An inactive console session blocks shortcuts")
        expect(!UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: [onConsole: true, loggedIn: false]),
               "An incomplete login blocks shortcuts")
        expect(!UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: [:])
               && !UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: [onConsole: "true", loggedIn: "true"]),
               "Missing or malformed session properties block shortcuts")
        expect(UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: [onConsole: NSNumber(value: 1), loggedIn: NSNumber(value: 1), locked: NSNumber(value: 0)]),
               "Session policy accepts macOS NSNumber flags")
    }

    private static func checkTranscripts() {
        expect(ParagraphFormatter.format(" \n\t ").isEmpty && WordCounter.count(in: "") == 0,
               "Empty transcripts remain empty")
        let bilingual = "Astăzi testez dictarea în română. I am testing local English dictation."
        expect(ParagraphFormatter.format(bilingual) == bilingual,
               "Short Romanian and English transcripts preserve diacritics and punctuation")
        expect(WordCounter.count(in: "Astăzi testez dictarea locală") == 4,
               "Word counting handles Romanian diacritics")

        let sentences = [
            "The first sentence has several words.",
            "The second sentence has several words.",
            "The third sentence has several words.",
            "The fourth sentence has several words.",
            "The fifth sentence must remain present."
        ]
        let formatted = ParagraphFormatter.format(sentences.joined(separator: " "))
        expect(formatted == sentences.prefix(4).joined(separator: " ") + "\n\n" + sentences[4],
               "Paragraph splitting retains the sentence after the four-sentence limit")
        expect(ParagraphFormatter.format("  Hello world.  \n") == "Hello world.",
               "Transcript formatting trims surrounding whitespace")
    }

    /// Parakeet v3 and Ultra can only filter the Unicode script, so the picker must not offer
    /// language codes that do nothing, and new modes must start on the Latin filter.
    private static func checkLanguagePolicy() {
        let models = TranscriptionModelRegistry.models
        guard let ultra = models.first(where: { $0.name == "parakeet-ultra" }),
            let v3 = models.first(where: { $0.name == "parakeet-tdt-0.6b-v3" }),
            let unified = models.first(where: { $0.name == "parakeet-unified-0.6b" }),
            let whisper = models.first(where: { $0.name == "ggml-large-v3-turbo-q5_0" })
        else {
            expect(false, "Registry lists the Parakeet and Whisper models used for dictation")
            return
        }

        for model in [ultra, v3] {
            expect(Set(model.supportedLanguages.keys) == ["auto", "latin"],
                   "\(model.displayName) offers only automatic detection and the Latin script filter")
            expect(TranscriptionLanguageSupport.validLanguageOrFallback(nil, for: model) == "latin",
                   "\(model.displayName) modes start on the Latin script filter")
            expect(TranscriptionLanguageSupport.validLanguageOrFallback("ro", for: model) == "latin",
                   "\(model.displayName) replaces a stored language code that has no effect with the filter")
            expect(TranscriptionLanguageSupport.validLanguageOrFallback("auto", for: model) == "auto",
                   "\(model.displayName) keeps an explicit automatic detection choice")
        }
        expect(TranscriptionLanguageSupport.validLanguageOrFallback(nil, for: whisper) == "auto",
               "Whisper modes start on automatic detection")
        expect(TranscriptionLanguageSupport.validLanguageOrFallback("latin", for: whisper) == "auto",
               "Whisper never receives the Parakeet script key")
        expect(TranscriptionLanguageSupport.validLanguageOrFallback("ro", for: whisper) == "ro",
               "Whisper keeps an explicit Romanian choice")
        expect(TranscriptionLanguageSupport.validLanguageOrFallback(nil, for: unified) == "en",
               "English-only Parakeet stays on English")
    }

    /// Eclipse's socket lines: what Voce sends, which commands it accepts, and how it splits the stream.
    private static func checkNotchProtocol() {
        let processing: [RecordingState] = [.transcribing, .enhancing, .busy]
        expect(processing.allSatisfy { NotchDictationState($0) == .processing },
               "Transcribing, enhancing and busy all reach Eclipse as processing")
        expect(NotchDictationMessage(state: .recording, level: 0.42).line
               == Data(#"{"level":0.42,"state":"recording","type":"dictation"}"#.utf8 + [0x0A]),
               "A dictation message is one JSON object with state and level, ending in a newline")
        expect(NotchDictationMessage(state: .idle).level == 0, "The hello and state changes carry level 0")
        expect([1.7, -0.3, .nan].map { NotchDictationMessage(state: .recording, level: $0).level } == [1, 0, 0],
               "Levels are clamped to 0...1")

        let command = { (line: String) in NotchCommand(line: Data(line.utf8)) }
        expect(command(#"{"type":"presenting","available":true}"#) == .presenting(true)
               && command(#"{"type":"presenting","available":false}"#) == .presenting(false),
               "Presenting replies carry availability")
        expect(command(#"{"type":"stop"}"#) == .stop && command(#"{"type":"cancel","extra":1}"#) == .cancel,
               "Stop and cancel decode, ignoring extra fields")
        expect([#"{"type":"presenting"}"#, #"{"type":"reboot"}"#, #"{"type":7}"#, "[]", "stop", ""]
                .allSatisfy { command($0) == nil },
               "Unknown types, missing fields and malformed lines are ignored")

        var framer = NotchLineFramer()
        expect(framer.append(Data(#"{"type":"st"#.utf8)).isEmpty, "A partial line waits for its newline")
        expect(framer.append(Data(#"op"}\#n{"type":"cancel"}\#n"#.utf8)).compactMap(NotchCommand.init(line:))
               == [.stop, .cancel], "Lines split across reads and several lines per read both decode")
        let oversized = Data(repeating: 0x61, count: NotchLineFramer.maxLineBytes + 1)
        expect(framer.append(oversized).isEmpty, "An oversized line yields nothing")
        expect(framer.append(Data(#"aaa\#n{"type":"stop"}\#n"#.utf8)).compactMap(NotchCommand.init(line:)) == [.stop],
               "The rest of an oversized line is dropped and the next line still decodes")
    }

    /// The manual update check: what the build reports, how GitHub's answer reads and what Terminal runs.
    private static func checkUpdateCheck() {
        let local = "3c2a404" + String(repeating: "a", count: 33)
        let build = AppBuild(info: ["CFBundleShortVersionString": "0.1.0", "SottoChannel": "beta", "SottoCommit": local])
        expect(build.channel == .beta && build.commit == local && build.summary == "0.1.0 · beta · 3c2a404",
               "A build.sh build reports version, channel and short commit")
        let unexpanded = AppBuild(info: ["CFBundleShortVersionString": "0.1.0", "SottoChannel": "", "SottoCommit": ""])
        expect(unexpanded.channel == nil && unexpanded.commit == nil && unexpanded.summary == "0.1.0 · local build",
               "A build without git or channel is a local build")

        let answer = { (status: Int, remaining: String?, body: String) in
            UpdateCheck.outcome(localCommit: local, status: status, rateLimitRemaining: remaining, body: Data(body.utf8))
        }
        let remote = String(repeating: "b", count: 40)
        expect(answer(200, "59", local.uppercased() + "\n") == .success(.upToDate),
               "The same SHA, in any case and with a trailing newline, is up to date")
        expect(answer(200, "59", remote) == .success(.updateAvailable(commit: remote)),
               "A different SHA is an update")
        expect(answer(200, "59", "{\"sha\":\"\(remote)\"}") == .failure(.unexpectedResponse)
               && answer(200, "59", String(remote.dropLast())) == .failure(.unexpectedResponse),
               "Anything but one full SHA is rejected")
        expect(answer(403, "0", "") == .failure(.rateLimited) && answer(429, nil, "") == .failure(.rateLimited)
               && answer(403, "12", "") == .failure(.httpStatus(403)),
               "Rate limits are told apart from other refusals")
        expect(UpdateCheck.failure(for: URLError(.notConnectedToInternet)) == .offline
               && UpdateCheck.failure(for: URLError(.timedOut)) == .timedOut,
               "Offline and timeout errors get their own messages")

        let request = UpdateCheck.request(for: .beta)
        expect(request.url?.absoluteString == "https://api.github.com/repos/AndreiStolojan/Sotto/commits/beta"
               && request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.sha"
               && request.httpMethod == "GET" && request.httpBody == nil,
               "The check is a bodiless GET for the channel's branch head")
        expect(UpdateCheck.request(for: .stable).url?.lastPathComponent == "main", "Stable follows main")

        let installer = "curl -fsSL https://raw.githubusercontent.com/AndreiStolojan/Sotto/main/install.sh | bash"
        expect(UpdateChannel.stable.installCommand == installer
               && UpdateChannel.beta.installCommand == installer + " -s -- --beta",
               "Each channel updates with its README install command")
        let script = UpdateCheck.updateScript(for: .beta)
        expect(script.hasPrefix("#!/bin/bash\n") && script.contains("set -euo pipefail\n" + UpdateChannel.beta.installCommand + "\n"),
               "The update script runs the beta install command and stops on failure")
    }
}
