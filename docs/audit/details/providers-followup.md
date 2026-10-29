# Sotto providers audit: follow-up repair pass

Branch `fix/repository-audit`, shared checkout. No commits, no PR. Ownership unchanged from `/tmp/sotto-audit-providers.md`.

## Fixed in this pass

### 1. High: Whisper downloads used mutable URLs with no integrity check
- Files: new `Voce/Features/ModelLibrary/State/WhisperModelCatalog.swift`, `WhisperModelManager.swift`, `Models/TranscriptionModel.swift` (removed the `resolve/main` `downloadURL`).
- Fix: every registry Whisper model and its Core ML archive downloads from `huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/...`. Each file must match its byte size and SHA-256 (CryptoKit, streamed, cancellable, off the main actor) before it is installed. A model missing from the catalog fails with the existing "%@ download failed" notification.
- Source of the values: `https://huggingface.co/api/models/ggerganov/whisper.cpp` (`sha` = that commit) and `/api/models/ggerganov/whisper.cpp/tree/<commit>` (`size`, `lfs.oid` = SHA-256). The tree at the pinned commit matched `tree/main` exactly. I also downloaded `ggml-tiny-encoder.mlmodelc.zip` at the pinned commit, and its `sha256sum` matched the catalog. No value was typed by hand from memory.

### 2. High: Core ML install was blocked for large-v2, and the ZIP checks parsed tool output
- Finding: the published `ggml-large-v2-encoder.mlmodelc.zip` contains `ggml-large-encoder.mlmodelc/`, not `ggml-large-v2-encoder.mlmodelc/`. The previous validator rejected it as `missingEncoder`. Before the audit, Zip.swift extracted it under the wrong name, so whisper.cpp never found it. Confirmed by reading the central directories of all 11 published encoder archives with HTTP range requests.
- Fix: `WhisperCoreMLArchive` was rewritten. It no longer uses `zipinfo` or `unzip`:
  - Reads the ZIP end record and central directory itself. Rejects ZIP64, multi-part archives, encryption, methods other than stored or deflate, and a central directory that is misplaced or larger than 1 MiB.
  - Caps are enforced before any write: at most 256 entries and 2 GiB total uncompressed (the largest published encoder is 1.28 GB in 16 entries).
  - Names must be printable ASCII without backslashes, under `<archive root>/` or `__MACOSX/`, with no empty, `.` or `..` components. Case-insensitive duplicates are rejected. A Unix file mode other than regular file or directory (for example a symlink) is rejected. A directory entry must have no data, and a stored entry's sizes must agree.
  - Each local header must repeat the central directory name, and entry data must end before the central directory. Overlapping entries (the overlapping-file ZIP bomb) are rejected.
  - Extraction writes only into a fresh staging directory. It never overwrites, skips `__MACOSX`, and streams 1 MiB chunks. Deflate uses Apple `Compression` `OutputFilter(.decompress, using: .zlib)` (raw DEFLATE), and an entry aborts as soon as its output passes the declared size. The final size must match exactly.
  - The archive root is renamed to the name whisper.cpp expects (`<model>-encoder.mlmodelc`), so large-v2 Core ML now installs correctly.
  - CRC-32 is not checked. The whole archive's SHA-256 is verified before extraction, which is a stronger check.

### 3. Medium: a failed commit deleted the previous install
- Both the main `.bin` and the encoder directory used `removeItem` and then `moveItem`. If the move failed, the old install was lost.
- Fix: `WhisperCoreMLArchive.replaceItem` moves the existing item into the staging directory, moves the new one in, puts the old one back if that move fails, and deletes the backup only after success. The main model and the Core ML encoder both use it.

### 4. Medium: data race and logical interleaving in FluidAudioTranscriptionService
- File: `Providers/Transcription/FluidAudio/FluidAudioTranscriptionService.swift`.
- Trigger: the prewarm `loadModel`, batch `transcribe`, file import, `cleanup`, and the streaming provider's `getOrLoadModels`, `detectedSpeechSegments` and `preparedSpeechAudio(in:)` ran on the generic executor in parallel against one plain class. This could produce torn reads and writes of the manager properties, a cleanup that released managers during inference, and Nemotron `setLanguage`/`reset`/`process`/`finish` sequences from two requests mixing.
- Fix: the class is now an `actor`, and every public operation runs through a private FIFO `exclusively` gate that hands ownership straight to the next waiter. Internal calls use non-gated private variants, so there is no re-entrant deadlock. `cleanup` now waits for a running transcription. The `loadingTask` deduplication was removed, because the gate already serializes loads. `transcribe` and `loadModel` check cancellation after they get the gate.
- Pinned FluidAudio `762baf6733ca0f0dbeb1ce335363fc75066bd2c9` was cloned and checked. `AsrManager`, `UnifiedAsrManager`, `StreamingNemotronMultilingualAsrManager` and `VadManager` are actors. `AsrModels` and `VadSegment` are `Sendable`, so they can cross the actor boundary. All the signatures used match.
- Callers need no source change. `TranscriptionServiceRegistry`, `VoceEngine.swift:388`, `StreamingTranscriptionService` and `FluidAudioStreamingProvider` already `await` these methods, and nothing relies on class identity. One trade-off: a streaming VAD pass now waits behind a running batch transcription on the same service, for example a file import during live dictation.

### 5. Dependency check: AudioConverter
- At the pinned FluidAudio revision, `AudioConverter` is `final class ... Sendable`. It is stateless, because it creates a new `AVAudioConverter` for each operation. `resampleAudioFile(_ url: URL) throws -> [Float]` decodes any `AVAudioFile` format and returns 16 kHz mono Float32. The Whisper and FluidAudio uses are correct and safe to share.

## Reviewed, no change
- ProcessRunner: the cancellation states (before launch, between storing the continuation and launch, after exit) all resume the continuation exactly once. The timeout and the post-SIGKILL fallback prevent hangs. Pipes and the termination-handler cycle are released in `finish`. Remaining known limits:
  - There is a microsecond window between Foundation reaping the root and `hasExited` being set.
  - Descendant PIDs could be reused within the 2 s grace period. macOS assigns PIDs sequentially, so this would need a full PID wrap.
  - A detached grandchild that keeps stdin open blocks one global-queue writer thread until it exits.

  Process groups would remove these, but they need posix_spawn in place of Foundation `Process`. I judged that too broad for this pass. With the parent's Zip removal, ProcessRunner no longer runs any archive tools.

## Validation
- Executed (Linux, `swift:6.2-bookworm`, Swift 6.2): `bash scripts/test-audit-providers.sh` compiled the production `WhisperCoreMLArchive.swift` with `Tests/AuditProviders/CoreMLArchiveTests.swift`. 23 checks passed, 0 failed. The checks cover path rules, symlink mode, backslash and control characters, case-insensitive duplicates, missing encoder, overlapping entries, data past the central directory, total-size and entry-count caps, non-ZIP input, stored extraction without `__MACOSX`, a failed commit restoring the previous install, and the root rename.
- Executed: the production reader listed the real pinned `ggml-tiny-encoder.mlmodelc.zip`: 8 entries, 16,470,214 bytes, 5 deflated. These match `zipinfo`.
- Pending on macOS (not run, no Xcode here):
  - `scripts/test-audit-providers.sh` also builds `ProviderAuditTests.swift`: the ProcessRunner checks, plus a real deflated `zip -qry` archive that must inflate byte-exactly, a `zip -y` symlink rejected, and a Python `../` entry rejected.
  - The app build, which compiles `WhisperModelCatalog` (CryptoKit), the `OutputFilter` deflate path, and the FluidAudio actor conversion. The `withCheckedContinuation` call inside the actor relies on Swift 6 compiler isolation inheritance (Xcode 16+, already required by the macOS 15 target).
  - An end-to-end download of a pinned model and its Core ML encoder.

## Remaining limitations and notes for the parent
- `scripts/test-audit-providers.sh` now runs the portable archive tests on any host and the ProcessRunner tests only on Darwin. The CI wiring can stay as is.
- Users who installed large-v2 Core ML before this change may have a stray `ggml-large-encoder.mlmodelc` directory in the models folder. It is unused and harmless. No migration was added.
- FluidAudio `ModelHub` download integrity stays inside the dependency. I did not review it in this pass.
- `whisper_full` still cannot be cancelled mid-run.
- Unchanged from the first report: `TranscriptionDelivery.swift` public logging of command output (outside my ownership), and the `OfflineTranscribeCppService` unload-after-use retention policy, which is a product decision and was left untouched as instructed.
