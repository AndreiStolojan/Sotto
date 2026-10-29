# Sotto audit: providers area

Branch `fix/repository-audit`, shared checkout. No commits, no PR. Linux aarch64 host: no Swift or Xcode, so nothing below was compiled or run. The macOS tests are written but did not run here.

Ownership: `Voce/Infrastructure/Providers/**`, `Voce/Infrastructure/SystemIntegration/Processes/**`, `Voce/Infrastructure/SystemIntegration/Context/**`, `Voce/Features/ModelLibrary/**`, `scripts/test-audit-providers.sh`, `Tests/AuditProviders/`.

## Fixed findings

### 1. High: LocalCLIService could deadlock, ignored cancellation and orphaned children
- File: `Voce/Infrastructure/Providers/Enhancement/LocalCLI/LocalCLIService.swift`
- Trigger: a prompt larger than the pipe buffer (about 64 KiB) on stdin, a command that writes more than the buffer to stdout or stderr, or an enhancement task that is cancelled.
- Impact: stdin was written synchronously before stdout and stderr were read, and the pipes were drained only after exit, so a full pipe deadlocked until the timeout. `terminationHandler` was installed after launch and the stdin write, so a fast exit could be missed and the run reported as a timeout. Task cancellation was ignored, so the command kept running. `Process.terminate()` signalled only `zsh`, so CLI children (claude, codex, pi) survived a timeout. Output had no size limit, and invalid UTF-8 became an empty string.
- Fix: new shared `ProcessRunner` (`Processes/ProcessRunner.swift`). It installs the termination handler before launch, writes stdin on its own queue with `F_SETNOSIGPIPE`, drains both pipes concurrently with a 1 MiB cap per stream, and handles cancellation through `withTaskCancellationHandler`. On timeout or cancellation it captures the process tree once, sends SIGTERM, then sends SIGKILL to the original targets that are still alive after the grace period, even when the root already exited. A reaped root PID is never signalled again. LocalCLI now throws the new `LocalCLIError.outputIncomplete` when stdout was capped or did not reach EOF within the drain deadline, so a partial enhancement is never pasted. PATH discovery, which can spend seconds in login shells, now runs on a dispatch queue through `ShellCommandEnvironment.resolvePreferredPATH`.
- Validation: `Tests/AuditProviders/ProviderAuditTests.swift` covers 4 MiB in and out through `cat`, simultaneous full stdout and stderr, a child that ignores stdin (EPIPE, not SIGPIPE), separate stdout and stderr, exit status, launch failure, timeout, and cancellation where the shell exits on SIGTERM while its orphaned child ignores SIGTERM and must still get SIGKILL. Run on macOS with `bash scripts/test-audit-providers.sh`. Not run here.

### 2. Medium: CustomCommandDeliveryRunner buffered without limit and ignored cancellation
- File: `Voce/Infrastructure/SystemIntegration/Processes/CustomCommandDeliveryRunner.swift`
- Trigger: a delivery command that prints a lot of output, or a cancelled caller.
- Impact: stdout and stderr were buffered without a limit (unbounded memory). Cancellation was not handled. The stdin write could raise SIGPIPE when the command exited without reading stdin (whether the app survived depended on the process-wide SIGPIPE disposition).
- Fix: the runner now goes through `ProcessRunner`, keeping its public API and error mapping. About 280 lines of hand-written process code were removed. The tree-kill logic now lives in `ProcessTree`.
- Validation: same tests as item 1. The caller (`TranscriptionDelivery.swift`) needed no changes.

### 3. Medium: BrowserURLService misread results and logged visited URLs publicly
- File: `Voce/Infrastructure/SystemIntegration/Context/BrowserURLService.swift`
- Trigger: a URL containing "error" (for example `https://example.com/error-codes`), an AppleScript failure, or a hung `osascript`.
- Impact: any URL containing "error" was rejected. stderr was merged into stdout and the exit status was ignored, so error text could be returned as the URL. The URL was logged with `privacy: .public`. A timeout sent only `terminate()` and never escalated. The output was read after exit (same full-pipe risk as item 1).
- Fix: `osascript` runs through `ProcessRunner` with a 64 KiB cap and a 0.5 s grace period before SIGKILL. A nonzero status maps to `executionFailed`. Only stdout is used. The URL and stderr are logged as `.private`. The substring check is gone. The bundled scripts (`Voce/Resources/*URL.scpt`) only `return URL` and fail through osascript's exit status, which was confirmed by reading them.

### 4. High: Whisper read audio as a fixed 44-byte PCM16 WAV
- File: `Voce/Infrastructure/Providers/Transcription/Whisper/WhisperTranscriptionService.swift`
- Trigger: any WAV whose data does not start at byte 44. The recorder writes WAV through `ExtAudioFileCreateWithURL` (`CoreAudioRecorder.swift:638`), and Core Audio WAV files can carry extra chunks, such as FLLR padding, before `data`. Also any file that is not 16 kHz mono PCM16 (for example the warmup `sound7.wav`), and any odd-length file.
- Impact: header bytes were decoded as audio. A file with an odd number of bytes after the header trapped on `data[$0..<$0 + 2]` (crash). A wrong sample rate or channel count produced garbage transcripts.
- Fix: `audioConverter.resampleAudioFile(_:)` from FluidAudio decodes and resamples to 16 kHz mono Float32. FluidAudio and transcribe.cpp already use this exact call at the pinned FluidAudio revision (`FluidAudioTranscriptionService.swift:228`, `OfflineTranscribeCppService.swift:109`), so the API is verified in the repo. `Infrastructure/Audio` was read but not edited.

### 5. Medium: Whisper context lifetime, interleaving and dangling C strings
- Files: `Whisper/LibWhisper.swift`, `Whisper/WhisperTranscriptionService.swift`, `ModelLibrary/State/WhisperModelManager.swift`
- Triggers and impact:
  - `setLanguage`, `setPrompt`, `fullTranscribe` and `getTranscription` were separate actor hops. Two transcriptions on the shared context (a dictation plus the warmup, or file import) could interleave, so one request could read the other's language, prompt or segments.
  - `cleanupResources` and `unloadModel` called `releaseResources()` on a context that a transcription might be using. Between hops that produced an empty transcript or `whisperCoreFailed`.
  - The service stored the context in an instance property shared by concurrent calls.
  - `params.language` and `params.initial_prompt` were pointers taken out of `withUnsafeBufferPointer`, and `vad_model_path` came from a temporary `NSString.utf8String`. Both outlived their valid scope (undefined behavior).
  - `loadModel` had no reentrancy guard, and a load that finished after cleanup put the context back.
  - Deleting the loaded model kept its context loaded.
- Fix: `WhisperContext.transcribe(samples:language:prompt:)` runs the whole transcription in one actor turn, and all C strings stay inside `withCString` scopes. The service keeps the context in a local variable, so a private context is freed when the request ends. The manager drops its reference instead of calling `releaseResources` (removed), so whisper.cpp memory is freed once in-flight users finish. `loadModel` skips when a load is already in progress and discards a load that a `contextGeneration` change made stale. `deleteModel` unloads the deleted model if it is loaded. The unused `setLanguage`, `releaseResources` and `TaskDelegate` were removed.

### 6. High (security): unsafe Core ML ZIP extraction (finding confirmed by the parent)
- File: `ModelLibrary/State/WhisperModelManager.swift`, new `ModelLibrary/State/WhisperCoreMLArchive.swift`
- Trigger: a malicious or tampered `<model>-encoder.mlmodelc.zip` from the mutable `resolve/main` URL.
- Impact: the pinned Zip.swift joins entry paths without containment and extracted straight into the live models directory with `overwrite: true`. That allowed `../` writes outside the directory, overwriting other models, and symlink tricks. The unzip also ran synchronously on the main actor.
- Fix: `WhisperCoreMLArchive.install`:
  1. `zipinfo -1` and `zipinfo -s` list the archive first. Every entry must be under `<name>-encoder.mlmodelc/` (`__MACOSX/` is tolerated but never extracted). Absolute paths, `..` components, backslashes, NUL bytes, any other top-level entry and any symlink entry are rejected.
  2. `/usr/bin/unzip -qq -n zip "<name>/*" -d <fresh staging dir>` extracts only the encoder.
  3. The extracted tree is checked again: the only top-level item must be the encoder, it must be a real directory, and nothing inside may be a symlink.
  4. Only then does the encoder replace the installed copy.

  Everything runs off the main actor through `ProcessRunner` and is cancellable. `import Zip` was removed. WhisperModelManager was the only Swift user of Zip, so the parent can remove the package from `Voce.xcodeproj` (parent owns the project).
- Validation: entry validation unit checks (traversal, absolute, backslash, unrelated top level, symlink flag, missing encoder, `__MACOSX`). End-to-end checks: a valid `zip -y` archive installs and replaces the old encoder, a symlink archive is rejected before extraction, and a Python-built `../` archive is rejected with nothing written outside. Not run here.

### 7. Medium: Whisper download held the model in memory, blocked the main thread, and handled Core ML failure badly
- File: `ModelLibrary/State/WhisperModelManager.swift`
- Triggers and impact:
  - The download was read into `Data` (mapped) and then rewritten with `data.write(.atomic)` on the main actor. For the 2.9 GB large models that froze the UI and doubled the disk writes.
  - When the main model downloaded but the optional Core ML encoder failed, the model was on disk but missing from `availableModels` until the next launch, with no user-visible error.
  - All download errors were silent.
  - Cancelling during the main download deleted `modelsDirectory/<name>.bin`, even when that file was an existing install.
  - A late progress callback after completion could re-create a progress key, leaving the card stuck in a downloading state.
- Fix: URLSession's file is moved into a per-download staging directory (`modelsDirectory/.downloads/<uuid>`, removed on exit, and stale copies cleared by `loadAvailableModels`). It is renamed into place only after success. Main model failures show "%@ download failed". A Core ML failure shows a warning and still lists the main model. Cancellation never touches installed files. Progress updates are accepted only while their key is active.

### 8. Low: FluidAudio download failures were silent
- File: `ModelLibrary/State/FluidAudioModelManager.swift`
- Fix: a non-cancellation failure now shows "%@ download failed", matching transcribe.cpp.

### 9. Low: FluidAudio streaming logged and emitted cancellation as an error on commit
- File: `Providers/Transcription/FluidAudio/Streaming/FluidAudioStreamingProvider.swift`
- Trigger: `commit()` cancels a transcription pass in progress.
- Impact: a spurious `.error(CancellationError)` event and an error log.
- Fix: the pass returns quietly on `CancellationError`. The final pass already covers the remaining audio.

### 10. Low: PATH discovery shell inherited the app's stdin
- File: `Processes/ShellCommandEnvironment.swift`
- Fix: discovery now sets stdin to `/dev/null`, which matters for the `-ilc` interactive probe.

## Findings outside my ownership (for the parent)
- `Voce/Features/Recording/Workflows/TranscriptionDelivery.swift:~125` logs custom command stdout and stderr with `privacy: .public`. That output is usually derived from the transcript, so dictated text reaches the unified log. Suggest `.private`.
- Remove the `Zip` Swift package from `Voce.xcodeproj` and `Package.resolved`. It is now unused.
- Wire `bash scripts/test-audit-providers.sh` into the macOS CI job. It needs `/usr/bin/unzip`, `zipinfo`, `zip` and `python3`, all present on macOS runners.

## Remaining risks and suggestions (not fixed)
- Whisper model integrity: models and Core ML zips come from `huggingface.co/ggerganov/whisper.cpp/resolve/main` with no pinned revision or checksum. HTTPS and the 2xx check are the only integrity checks. Fix: pin a revision and SHA-256 per model, as transcribe.cpp already does. I did not add hashes because that needs values verified against the primary source, and I did not browse for them.
- FluidAudio `ModelHub` integrity and caching are inside the dependency. Not verified, because no source was available offline.
- ZIP bombs: extraction has no size or file-count cap beyond the 10-minute tool timeout. A tampered archive could fill the disk. Suggestion: sum the uncompressed sizes from `zipinfo -t` and cap them.
- PID reuse: a descendant that exits and has its PID reused within the 2 s grace period could receive SIGKILL. There is also a tiny window between Foundation reaping the root and `terminationHandler` setting `hasExited`. Process groups would remove this risk, but Foundation `Process` does not expose `setpgid`.
- `whisper_full` cannot be cancelled once running (no abort callback is wired). Cancellation is checked only before it starts.
- `FluidAudioTranscriptionService` is a plain class with mutable state reached from the prewarm task and transcription tasks. This is a possible data race. Converting it to an actor is a broader change. Unverified at runtime.
- `OfflineTranscribeCppService.releaseModel` unloads the model after every transcription, so each dictation reloads the 1.5 GB model. This looks deliberate for memory, but it costs latency. Needs a product decision.
- `TranscribeCppModelManager.isModelDownloaded` reads the checksum file on every SwiftUI evaluation. Minor performance cost. `reportFailure` uses an unlocalized title.
- `clearDownloadedModels` removes `.bin` files but not the Core ML directories. No caller was found.
- `ProviderLocalManagementView` timeout picker shows a blank selection for saved values outside its tag list. Cosmetic.
- ProcessRunner uses `F_SETNOSIGPIPE` and `NSLock.withLock`. Both are standard on Darwin, and the repo already uses `withLock`, but the new code is not compiled here. The first macOS build should confirm it.

## Files examined
Read fully, in ownership:
- Infrastructure/Providers: Enhancement/EnhancementRequestSettings.swift, Enhancement/AIChatCompletionService.swift, Enhancement/Ollama/OllamaService.swift, Enhancement/LocalCLI/LocalCLIService.swift, Transcription/AppleSpeech/NativeAppleTranscriptionService.swift, Transcription/AppleSpeech/NativeAppleSpeechAssetManager.swift, Transcription/TranscribeCpp/OfflineTranscribeCppService.swift, Transcription/TranscribeCpp/TranscribeCppTranscriptionService.swift, Transcription/TranscribeCpp/TranscribeCppModelCatalog.swift, Transcription/Whisper/WhisperTranscriptionService.swift, Transcription/Whisper/WhisperPrompt.swift, Transcription/Whisper/WhisperModelProvider.swift, Transcription/Whisper/VADModelManager.swift, Transcription/Whisper/LibWhisper.swift, Transcription/FluidAudio/FluidAudioTranscriptionService.swift, Transcription/Contracts/StreamingTranscriptionProvider.swift, Transcription/FluidAudio/Streaming/WordAgreementEngine.swift, FluidAudioNemotronStreamingProvider.swift, FluidAudioStreamingProvider.swift, FluidAudioUnifiedStreamingProvider.swift
- SystemIntegration/Processes: CustomCommandDeliveryRunner.swift, ShellCommandEnvironment.swift, plus the new ProcessRunner.swift
- SystemIntegration/Context: TriggerInstalledApps.swift, ActiveWindowService.swift, BrowserURLService.swift, TriggerAppIconCache.swift
- Features/ModelLibrary: Components/FluidAudioModelCardView.swift, NativeModelCardView.swift, NativeAppleLanguageAssetControl.swift, TranscribeCppModelCardView.swift, ModelCardView.swift, ProviderSharedViews.swift, WhisperModelCardView.swift, LanguageSelectionView.swift; Views/ProviderLocalManagementView.swift, ModelSettingsPanel.swift, ModelManagementView.swift; State/TranscribeCppModelManager.swift, WhisperModelManager.swift, TranscriptionModelManager.swift, FluidAudioModelManager.swift, WhisperModelWarmupCoordinator.swift, plus the new WhisperCoreMLArchive.swift; Models/TranscriptionModel.swift, TranscriptionRealtimeSupport.swift, TranscriptionModelRegistry.swift
- Models/LanguageDictionary.swift: the logic (`TranscriptionLanguageSupport`, `forProvider`, `forCodes`) was read. The static language tables were skimmed, not proofread entry by entry.

Read-only callers and context outside ownership: Infrastructure/Audio/PCMAudioConverter.swift, CoreAudioRecorder.swift (WAV writer lines), AudioFileProcessor.swift (signatures); Features/Recording/Workflows/VoceEngine.swift (load and cleanup paths), TranscriptionServiceRegistry.swift, TranscriptionService.swift, TranscriptionDelivery.swift (custom command call); Features/Enhancement/State/AIService.swift (LocalCLI wiring), Features/Enhancement/Workflows/AIEnhancementService.swift (timeout and retry); Features/Recording/Streaming/StreamingTranscriptionService.swift (error event handling); App/Voce.swift (unloadModel call); App/Notifications/NotificationManager.swift; Core/Transcription/VoceEngineError.swift; Voce/Resources/*URL.scpt; scripts/test-core.sh; Tests/CI/CoreTests.swift; .github/workflows/ci.yml; Package.resolved.

Not reviewed: the FluidAudio, transcribe.cpp, whisper.cpp and LLMkit dependency sources (unavailable offline). Zip.swift was verified by the parent.
