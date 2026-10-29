# Sotto audit: recording area

Scope: Voce/Infrastructure/Audio/**, Voce/Core/**, Voce/Features/{Recording,AudioImport,AudioSettings,History,Assistant,Enhancement}/**, Voce/Infrastructure/TextProcessing/**.
Branch fix/repository-audit. No commit, no PR exists. Linux aarch64: no Swift/Xcode, so **no Swift code was compiled or run**. Only shell syntax, shellcheck and a Python mirror of the CSV rule ran.

## Fixed findings

### 1. High: cancelled audio import keeps running and mutates or saves (AudioFileTranscriptionManager.swift)
- Trigger: Start, Cancel, Start again (or Clear) while a file is transcribing or enhancing.
- Impact: the old `processItem` kept awaiting the provider, then overwrote the shared item's status (the new run's item flipped back to pending, or to completed), and could insert a Transcription for a cancelled or cleared item. Enhancement `catch` turned cancellation into a saved "Enhancement failed" record. No check before persistence.
- Fix: `cancelProcessing()` bumps `processingGeneration`; each run carries its generation. `ensureCurrent(_:)` (task cancellation plus generation) runs after every await and right before insert/save; `setStatus` ignores stale runs; the loop stops on a stale generation; enhancement rethrows `CancellationError`.
- Validation: code review only (not compiled).

### 2. Medium: failed or cancelled imports leave permanent WAV files (same file)
- Trigger: any error or cancellation after `saveSamplesAsWav`.
- Impact: orphan `transcribed_*.wav` in Application Support/Recordings, never shown in History, never cleaned up.
- Fix: track `unsavedAudioURL` until save succeeds; delete it in the catch. On save failure, `modelContext.delete` the insert so a later autosave cannot persist a record without its audio.

### 3. High: retranscription reports success when the save failed (History/Workflows/AudioFileTranscriptionService.swift)
- Trigger: `modelContext.save()` throws in any branch.
- Impact: error was only logged; caller showed "Retranscription successful", the copied WAV was orphaned, the unsaved insert stayed in the context.
- Fix: one `save(_:)` helper that rolls back its own insert and throws; any throw after the copy removes the copy. Also: non-enhanced path now posts `.transcriptionCreated` (was missing), enhancement rethrows cancellation, `Task.checkCancellation()` before copy and before save, `isTranscribing` reset by `defer`.
- Also fixed: a registry the service creates itself (History views) is now cleaned up after each call, so FluidAudio and transcribe.cpp models no longer stay loaded per view instance. The engine's injected registry (menu bar, retry shortcut) is left alone.

### 4. Medium: AIEnhancementService turned cancellation into a provider error (AIEnhancementService.swift)
- Trigger: task cancelled during the request.
- Impact: generic catch wrapped `CancellationError` into `EnhancementError.customError`, so every caller saved "Enhancement failed: …" for a user cancel; the retry loop also kept going.
- Fix: rethrow `CancellationError`; `Task.checkCancellation()` at the top of each retry attempt.

### 5. Medium (privacy): custom command logging published transcript-derived text (TranscriptionDelivery.swift)
- Trigger: custom command output mode.
- Impact: stdout, stderr and `CustomCommandDeliveryError` descriptions (which embed stderr / launch messages) were logged with `privacy: .public`, readable by anyone with `log stream`. Commands commonly echo the transcript.
- Fix: log only duration and byte counts; failures log a fixed summary (`exit status=N stderrBytes=M`, `timed out`, etc.).

### 6. Medium: CSV export corrupts fields with a quote but no comma, or a CR (History/Export)
- Trigger: transcript like `say "hi"` or containing `\r` without a comma or LF.
- Impact: quotes were doubled but the field was not wrapped, so readers see a broken field; a lone CR ended the record.
- Fix: new `CSVField.escape` (RFC 4180: quote when the value has `"`, `,` or any newline character). Text stays literal.
- Formula exposure: assessed and deliberately **not** neutralized. `scripts/benchmark.py` compares `Original Transcript` exactly (`strict_exact`), so prefixing `'` would break it. Documented in `CSVField.swift`. Residual risk: a transcript starting with `= + - @` can evaluate as a formula if the CSV is opened in a spreadsheet app. Option for the user: an opt-in "spreadsheet-safe" export.
- Validation: `scripts/test-audit-recording.sh` (needs macOS) compiles CSVField alone, checks cases, and confirms Python `csv.DictReader(strict=True)` reads hostile values back literally. Here I ran a Python mirror of the rule: new rule round-trips, old rule fails.

### 7. Medium: imported audio could repeat at the end of each resampled chunk (AudioFileProcessor.swift)
- Trigger: importing a file not already 16 kHz mono (via AVAudioFile path).
- Impact: the input block returned the same buffer with `.haveData` on every call. Apple docs: the block is called "as necessary" and convert "attempts to fill the buffer to its capacity" (verified on developer.apple.com, convert(to:error:withInputFrom:) and AVAudioConverterInputStatus). With resampler latency, a second call re-fed the chunk, appending repeated audio.
- Fix: provide the chunk once, then `.endOfStream`; capacity rounded up plus 1024 frames for the flushed tail.
- Validation: docs plus code review; not run.

### 8. Medium: superseded recording start could delete a live pipeline's audio (VoceEngine.swift)
- Trigger: a start failure (throw from `startRecording` or `session.prepare`) arriving after the user cancelled, stopped, or began a new recording.
- Impact: the catch deleted `recordedFile`, set state idle, released models and dismissed the panel, possibly under a running pipeline or a newer session.
- Fix: catch returns early unless `activeRecordingStartID == startID`; the cancel/stop path already owns cleanup.

### 9. Low: re-enhance changed History metadata before the request (AudioPlayerView.swift, HistoryDetailActionBar.swift)
- Trigger: re-enhance fails.
- Impact: prompt and model name updated on the persisted record while the old enhanced text stayed, and autosave could persist the mismatch. AudioPlayerView also ignored save errors with `try?` and showed success.
- Fix: update metadata only with a result; AudioPlayerView now rolls back and shows the existing "Could not save re-enhancement" error (no new copy).

### 10. Low: waveform seek and timer (AudioPlayerView.swift)
- Seek now clamps to `0...duration` (a drag can report points outside the view); `startTimer` invalidates any earlier timer.

### 11. Low: device-list listener never removed (AudioDeviceManager.swift)
- `deinit` passed a different closure literal to `AudioObjectRemovePropertyListener`, which unregisters "the given" proc (Apple docs), so nothing was removed and the unretained refcon could dangle. Singleton, so practical impact is nil; fixed with one shared static proc.

### 12. Low: custom sound with a new extension orphaned the old file (CustomSoundManager.swift)
- Replacing `CustomStartSound.wav` with an `.mp3` left the `.wav` behind; now removed after a successful copy.

### 13. Low: collapsed import row copied the enhancement failure message (AudioImport/Views/AudioFileRow.swift)
- Trigger: an imported file whose enhancement failed; Copy or Save on the collapsed row.
- Impact: `enhancedText ?? text` copied or saved "Enhancement failed: …" instead of the transcript.
- Fix: collapsed copy/save uses `preferredHistoryText`, which History already uses to skip failure messages. The visible preview is unchanged.

### 14. Hardening: render-callback stop handshake (CoreAudioRecorder.swift)
- Stop stores `recordingActive = false` then waits for `renderCallbacksInFlight == 0`; the callback increments then loads the flag. That is a store→load (Dekker) pattern, which acquire/release does not order on ARM64. `AudioOutputUnitStop` very likely synchronizes in practice, so this was an unverified risk; switched those accesses to `.sequentiallyConsistent` (strengthening only).

## Confirmed, outside my ownership (for parent)
- CursorPaster.swift: overlapping paste sessions during the 100 ms pre-paste delay could paste another session's text, and `UInt64(seconds * 1e9)` traps on huge/infinite/NaN `clipboardRestoreDelay` from an imported backup (BackupImporter writes it unclamped). Both confirmed by reading; another agent's in-progress diff in this checkout already serializes sessions and clamps the delay. Not edited by me.
- WhisperTranscriptionService.swift (providers): when it creates its own context and `fullTranscribe` fails or `readAudioSamples` throws, the context is never released. `readAudioSamples` also assumes a 44-byte WAV header.
- TranscriptionDelivery's `notifyCustomCommandFailure` only logs; the user gets no visible notice that the custom command failed. Adding one is a copy/UX decision.

## Suggestions and unverified risks (not changed)
- CoreAudioRecorder resampling: per-buffer linear interpolation with `UInt32(frames * ratio)` floors each buffer (about 0.4% of samples lost at 48 kHz/512 frames) and has no anti-alias filter. A stateful AVAudioConverter would fix quality; needs on-device testing.
- CoreAudioRecorder and AudioDeviceManager CFString properties read via `&property` likely leak a +1 CFString per call (header says caller releases). Not verified against primary docs; small leak.
- Failed `switchDevice` after step 4 leaves the recording "active" but silent until stop (user does get an error notification).
- AudioFileProcessor: per-chunk peak normalization (gain jump every 50M frames) and up to ~400 MB chunk buffers for long stereo files; `saveSamplesAsWav` runs on the main actor.
- AudioTranscriptionManager builds a fresh registry per file, reloading FluidAudio/transcribe.cpp models for every queued item.
- VoceEngine model preload task can load a model after a very short session already ran `cleanupResources`, keeping it in memory until the next session.
- StreamingTranscriptionService `waitForFinalCommit` returns on the first committed event after stop, which may be an earlier segment for some providers.
- WaveformGenerator uses one sample per stride instead of the peak; `UInt32(audioFile.length)` traps above ~74 h of 16 kHz audio.
- ProcessingIndicator uses a `repeatForever` rotation (continuous repaint). Visual change, needs mockup approval.
- Assistant template refers to `<CONTEXT_INFORMATION>`, but context is injected under `# Context` with other tags.
- AudioSetupView calls `getCurrentDevice()` (full device resolution with several Core Audio queries) for every priority row on every render.
- CSV export and SaveIconButton report write errors only with `print`.

## Tests added (parent wires them)
- `scripts/test-audit-recording.sh`, `Tests/AuditRecording/CSVFieldTests.swift`. Requires macOS (`xcrun swiftc`) and python3. `bash -n` and shellcheck pass here; the Swift part did not run.

## Files changed by me
- Voce/Features/AudioImport/Workflows/AudioFileTranscriptionManager.swift
- Voce/Features/History/Workflows/AudioFileTranscriptionService.swift
- Voce/Features/History/Export/VoceCSVExportService.swift
- Voce/Features/History/Export/CSVField.swift (new)
- Voce/Features/History/Components/AudioPlayerView.swift
- Voce/Features/History/Components/HistoryDetailActionBar.swift
- Voce/Features/Enhancement/Workflows/AIEnhancementService.swift
- Voce/Features/Recording/Workflows/TranscriptionDelivery.swift
- Voce/Features/Recording/Workflows/VoceEngine.swift
- Voce/Features/AudioImport/Views/AudioFileRow.swift
- Voce/Infrastructure/Audio/AudioFileProcessor.swift
- Voce/Infrastructure/Audio/CoreAudioRecorder.swift
- Voce/Infrastructure/Audio/CustomSoundManager.swift
- Voce/Infrastructure/Audio/Devices/AudioDeviceManager.swift
- scripts/test-audit-recording.sh (new), Tests/AuditRecording/CSVFieldTests.swift (new)

## Files examined (all 86 in scope, every one read)
Every file was read in full. In view files I read styling modifiers but audited state, tasks, timers, bindings and actions; layout and styling were not judged (visual work needs mockup approval).
- Voce/Core/Enhancement/AIEnhancementOutputFilter.swift
- Voce/Core/Enhancement/AIPrompts.swift
- Voce/Core/Enhancement/EnhancementFailureFormatter.swift
- Voce/Core/Recording/RecordingState.swift
- Voce/Core/Transcription/VoceEngineError.swift
- Voce/Features/Assistant/State/AssistantSession.swift
- Voce/Features/Assistant/Workflows/AssistantChatService.swift
- Voce/Features/AudioImport/State/AudioFileQueueItem.swift
- Voce/Features/AudioImport/State/TranscriptionResultView.swift
- Voce/Features/AudioImport/Views/AudioFileRow.swift
- Voce/Features/AudioImport/Views/AudioTranscribeView.swift
- Voce/Features/AudioImport/Workflows/AudioFileTranscriptionManager.swift
- Voce/Features/AudioSettings/Views/AudioSetupView.swift
- Voce/Features/AudioSettings/Views/CustomSoundSettingsView.swift
- Voce/Features/Enhancement/Models/CustomPrompt.swift
- Voce/Features/Enhancement/State/AIService.swift
- Voce/Features/Enhancement/State/FillerWordManager.swift
- Voce/Features/Enhancement/Templates/PromptTemplates.swift
- Voce/Features/Enhancement/Views/EnhancementShortcutsView.swift
- Voce/Features/Enhancement/Views/FillerWordsSettingsView.swift
- Voce/Features/Enhancement/Views/PromptEditorView.swift
- Voce/Features/Enhancement/Views/PromptSelectionGrid.swift
- Voce/Features/Enhancement/Workflows/AIEnhancementService.swift
- Voce/Features/History/Components/AudioPlayerView.swift
- Voce/Features/History/Components/HistoryAudioPlayer.swift
- Voce/Features/History/Components/HistoryComponents.swift
- Voce/Features/History/Components/HistoryDetailActionBar.swift
- Voce/Features/History/Components/SaveIconButton.swift
- Voce/Features/History/Components/TranscriptionListItem.swift
- Voce/Features/History/Export/CSVField.swift
- Voce/Features/History/Export/VoceCSVExportService.swift
- Voce/Features/History/Models/Transcription+History.swift
- Voce/Features/History/Presentation/QuickHistoryController.swift
- Voce/Features/History/Views/HistoryAnalysisPanelView.swift
- Voce/Features/History/Views/HistorySettingsPanel.swift
- Voce/Features/History/Views/HistoryView.swift
- Voce/Features/History/Views/QuickHistoryViewModel.swift
- Voce/Features/History/Views/QuickHistoryView.swift
- Voce/Features/History/Views/TranscriptionDetailView.swift
- Voce/Features/History/Views/TranscriptionInfoPanel.swift
- Voce/Features/History/Workflows/AudioFileTranscriptionService.swift
- Voce/Features/History/Workflows/LastTranscriptionService.swift
- Voce/Features/Recording/Capture/Recorder+RecordingDeviceSetup.swift
- Voce/Features/Recording/Capture/Recorder.swift
- Voce/Features/Recording/Components/AudioVisualizerView.swift
- Voce/Features/Recording/Components/CircularRecorderButtonStyle.swift
- Voce/Features/Recording/Components/NotchShape.swift
- Voce/Features/Recording/Components/RecorderComponents.swift
- Voce/Features/Recording/Context/RecordingContextSnapshot.swift
- Voce/Features/Recording/Presentation/DockVisibilityController.swift
- Voce/Features/Recording/Presentation/MiniRecorderPanel.swift
- Voce/Features/Recording/Presentation/MiniWindowManager.swift
- Voce/Features/Recording/Presentation/NotchLink.swift
- Voce/Features/Recording/Presentation/NotchRecorderPanel.swift
- Voce/Features/Recording/Presentation/NotchSocket.swift
- Voce/Features/Recording/Presentation/NotchWindowManager.swift
- Voce/Features/Recording/Presentation/RecorderScreenResolver.swift
- Voce/Features/Recording/Presentation/RecorderUIManager.swift
- Voce/Features/Recording/Processing/TranscriptionOutputFilter.swift
- Voce/Features/Recording/State/RecorderStateProvider.swift
- Voce/Features/Recording/Streaming/StreamingTranscriptionService.swift
- Voce/Features/Recording/Views/EnhancementPromptPopover.swift
- Voce/Features/Recording/Views/MiniRecorderView.swift
- Voce/Features/Recording/Views/NotchRecorderView.swift
- Voce/Features/Recording/Workflows/DictationLatencyTrace.swift
- Voce/Features/Recording/Workflows/TranscriptionDelivery.swift
- Voce/Features/Recording/Workflows/TranscriptionPipeline.swift
- Voce/Features/Recording/Workflows/TranscriptionServiceRegistry.swift
- Voce/Features/Recording/Workflows/TranscriptionService.swift
- Voce/Features/Recording/Workflows/TranscriptionSession.swift
- Voce/Features/Recording/Workflows/VoceEngine+Assistant.swift
- Voce/Features/Recording/Workflows/VoceEngine+AudioInputFailure.swift
- Voce/Features/Recording/Workflows/VoceEngine+Protocols.swift
- Voce/Features/Recording/Workflows/VoceEngine.swift
- Voce/Features/AudioImport/Views/AudioFileRow.swift
- Voce/Infrastructure/Audio/AudioFileProcessor.swift
- Voce/Infrastructure/Audio/CoreAudioRecorder.swift
- Voce/Infrastructure/Audio/CustomSoundManager.swift
- Voce/Infrastructure/Audio/Devices/AudioDeviceConfiguration.swift
- Voce/Infrastructure/Audio/Devices/AudioDeviceManager+RecordingRouting.swift
- Voce/Infrastructure/Audio/Devices/AudioDeviceManager.swift
- Voce/Infrastructure/Audio/PCMAudioConverter.swift
- Voce/Infrastructure/Audio/SoundManager.swift
- Voce/Infrastructure/Audio/SoundPlaybackEngine.swift
- Voce/Infrastructure/Audio/SupportedMedia.swift
- Voce/Infrastructure/TextProcessing/ParagraphFormatter.swift
- Voce/Infrastructure/TextProcessing/WordCounter.swift

Read-only callers outside scope: CursorPaster, ClipboardManager, CustomCommandDeliveryRunner, BackupImporter (clipboard delay), WhisperTranscriptionService, FluidAudioTranscriptionService, TranscribeCppTranscriptionService, OfflineTranscribeCppService, RecordingShortcutManager, MenuBarView, scripts/benchmark.py, docs/benchmarks/README.md, scripts/test-core.sh, Tests/CI/CoreTests.swift.
Not reviewed: nothing in scope was skipped.
