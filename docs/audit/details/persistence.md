# Sotto audit: persistence area

Branch `fix/repository-audit`. No commits, pushes or PRs were made. No PR exists.
Environment: Linux aarch64. No macOS build, no Xcode, no XCTest. macOS tests were not run.
Validation available here: Swift 6.2.4 (`swift:6.2-bookworm`, network off) for frontend parse of every
touched file and for compiling and running pure-Foundation code.

## Findings and fixes

Severity scale: High = data loss, crash or security-relevant wrong behavior in normal use.
Medium = crash or data loss needing unusual input, or a feature silently not working.
Low = robustness or bounded-impact defect.

### 1. Auto Learn review proposals overwritten after a failed load (High, fixed)
- File: `Voce/Features/Dictionary/AutoLearn/AutoLearnReviewProposalStore.swift`
- Trigger: `loadIfNeeded` used `defer { isLoaded = true }`. A read error or a decode error on
  `auto-learn-review-proposals.json` still marked the store loaded with an empty array.
- Impact: the next `append`, `remove` or `update` saved the empty in-memory array over the file and
  destroyed every staged proposal. A single corrupt entry made the whole file undecodable.
- Fix: new `AutoLearnJSONArrayFile.load` (`Voce/Features/Dictionary/AutoLearn/AutoLearnJSONArrayFile.swift`).
  The store is marked loaded only after a successful load. Read errors propagate, so the next call retries.
  Elements decode one by one through a non-throwing wrapper, so bad entries are dropped individually.
  A file that is not a JSON array is moved aside to `<name>.corrupt-<time>-<uuid>.json` before the store
  starts empty, so a later save never overwrites unread bytes.
- Validation: parse-checked; the helper compiled on Linux Swift. Parent's portable tests cover scalar
  elements, preserved corrupt bytes and retry after read errors.

### 2. Auto Learn pending queue could crash on scalar or null entries (Medium, fixed)
- File: `Voce/Features/Dictionary/AutoLearn/AutoLearnPendingQueue.swift`
- Trigger: each array element was re-serialized with `JSONSerialization.data(withJSONObject:)` without
  `.fragmentsAllowed`. Apple documents that this API raises an Objective-C exception (not a Swift error)
  when the top-level object is not an array or dictionary. `try?` cannot catch it.
- Impact: a queue file containing `[1]`, `["x"]` or `[null]` crashes the app at launch when
  `AutoLearnService.configure` loads the queue. A non-array file stranded the queue permanently.
- Fix: the queue now uses the same `AutoLearnJSONArrayFile.load`, which never round-trips through
  `JSONSerialization`. Legacy field decoding in `QueuedCorrection.init(from:)` is unchanged.
- Validation: as finding 1.

### 3. Backup import stored unbounded numeric settings (High, fixed)
- Files: `Voce/Features/Settings/Backup/BackupImporter.swift`, new
  `Voce/App/Configuration/SettingsValueLimits.swift`, readers in
  `Voce/Infrastructure/SystemIntegration/Paste/CursorPaster.swift`,
  `Voce/Infrastructure/SystemIntegration/Media/MediaController.swift`,
  `Voce/Infrastructure/Persistence/Cleanup/TranscriptionAutoCleanupService.swift`,
  `Voce/Infrastructure/Persistence/Cleanup/AudioCleanupManager.swift`.
- Trigger and impact:
  - `clipboardRestoreDelay` huge -> `UInt64(seconds * 1e9)` traps in `CursorPaster.wait` after every paste.
  - `audioResumptionDelay` huge or infinite -> same trap in `MediaController` and `PlaybackController`.
  - `transcriptionRetentionMinutes` near `Int.max` -> `-minutes * 60` traps on every transcription.
  - `audioRetentionPeriod` of 0 or negative -> cutoff is now or in the future, so audio cleanup deletes
    every audio file. `Int.min` traps on negation.
- Fix: `SettingsValueLimits` holds the ranges the UI offers. Import clamps delays and skips retention
  values outside their range (clamping retention could delete history sooner than intended). Readers
  clamp independently, so a `defaults write` value is also safe: CursorPaster clamps the restore delay,
  `wait` ignores non-finite values, MediaController clamps on load and in `didSet`, transcript cleanup
  multiplies in floating point, audio cleanup refuses a retention under one day.
- Validation: `scripts/test-audit-persistence.sh` compiles the production `SettingsValueLimits.swift`
  with `Tests/AuditPersistence/SettingsValueLimitsTests.swift` and passed on Linux Swift 6.2.4.

### 4. Backup import of an empty or partial file deleted all modes and prompts (High, fixed)
- File: `Voce/Features/Settings/Backup/BackupImporter.swift`
- Trigger: `BackupFile` decodes missing `modeConfigs` and `customPrompts` as `[]`. The import dialog
  defaults to All categories.
- Impact: importing a general-only or hand-trimmed backup removed every mode (including the default)
  and every custom prompt.
- Fix: the prompts and modes categories are skipped when the backup holds none.
- Validation: parse-checked only.

### 5. Duplicate mode IDs in a backup crashed the next export (Medium, fixed)
- Files: `BackupImporter.swift`, `Voce/Features/Settings/Backup/ImportExportService.swift`
- Trigger: a backup repeating a mode ID was stored as is. Export builds
  `Dictionary(uniqueKeysWithValues:)` keyed by mode ID, which traps on duplicates.
- Fix: import keeps the first config per ID and goes through `replaceConfigurations`, which also posts
  the shortcut availability change that the direct assignment skipped. Export uses `uniquingKeysWith`.
  Mode shortcuts are applied after the new modes are in place, as before.
- Validation: parse-checked only.

### 6. Website triggers matched by substring, so any URL could activate a mode (High, fixed)
- Files: `Voce/Features/Modes/State/ModeConfig.swift`, new `Voce/Features/Modes/State/ModeWebsiteMatcher.swift`
- Trigger: `getConfigurationForURL` used `cleanedURL.contains(configURL)`. `https://evil.example/?claude.ai`,
  `https://claude.ai.evil.example` and `https://claude.ai@evil.example` all activated a `claude.ai` mode.
- Impact: a page could switch the user into a mode with screen capture, clipboard or selected-text
  context and a cloud AI provider, sending that context off-device.
- Fix: the URL is parsed with `URLComponents`. The trigger host must equal the URL host or be a parent
  domain of it (`slack.com` still matches `team.slack.com`). A trigger path matches whole segments
  (`icloud.com/mail` matches `/mail/inbox`, not `/mailbox`). `www.` and scheme are ignored, `host:port`
  triggers still work, an empty trigger matches nothing.
- Validation: compiled on Linux with a spot check (subdomain true, userinfo spoof false). Parent's
  portable tests cover spoofing and path and port boundaries.

### 7. Dashboard stale mark cleared by an earlier save; tab reopen never refreshed (Medium, fixed)
- Files: `Voce/Infrastructure/Persistence/Statistics/DashboardStatsSnapshotStore.swift`,
  `Voce/Features/Dashboard/State/DashboardStatsModels.swift`, `Voce/Features/Dashboard/Views/DashboardContent.swift`,
  `Voce/App/Voce.swift`
- Trigger: the background save removed the stale flag unconditionally, so a `markStale` between enqueue
  and write was lost. `shouldRefreshSnapshotAutomatically` never consulted the stale state, and stale
  was only marked while the Dashboard view was on screen.
- Impact: with more than 2,000 metrics, or with the Dashboard closed while dictating, reopening the
  Dashboard showed totals from earlier that day. The code comment promised "tab reopen still refreshes".
- Fix: a stale generation counter. The view reads it before loading, and the save clears the mark only
  if no newer `markStale` happened. The cache observes `sessionMetricsDidChange` from launch, and a
  stale cache forces a refresh on reopen.
- Validation: parse-checked only.

### 8. Cleanup deleted any stored audio path, and deleted files before the database save (High, fixed)
- Files: new `Voce/Infrastructure/Persistence/Cleanup/RecordingFileLocation.swift`,
  `TranscriptionAutoCleanupService.swift`, `AudioCleanupManager.swift`
- Trigger: every cleanup path called `removeItem` on whatever `audioFileURL` held.
- Impact: a crafted or corrupted record could delete any file the user owns. Files were removed before
  `modelContext.save()`, so a failed save left records pointing at deleted audio.
- Fix: `RecordingFileLocation.ownedFileURL` accepts only a `file:` URL whose resolved parent is the
  resolved Recordings directory. Transcript sweeps and the immediate-delete path delete the records,
  save, and only then delete files. The worker rolls back its own context on failure. The main-context
  path does not roll back, because that would discard unrelated unsaved edits.
- Validation: parse-checked. Parent's portable tests cover symlink and traversal rejection.

### 9. Orphan audio cleanup raced in-flight recordings and imports (Medium, fixed)
- File: `TranscriptionAutoCleanupService.swift`
- Trigger: at launch, every file in Recordings without a transcription row was deleted. Recording,
  audio import and retranscription write the file before the row exists.
- Impact: a recording started or file imported right after launch could lose its audio.
- Fix: only regular files last modified more than 24 hours ago are treated as orphans.
- Validation: parse-checked only.

### 10. Overlapping paste sessions pasted the wrong text and lost the user's clipboard (High, fixed)
- File: `Voce/Infrastructure/SystemIntegration/Paste/CursorPaster.swift`
- Trigger: two pastes within the 100 ms pre-paste delay or before the restore delay ended, for example
  a dictation finishing while Quick History or Paste Last runs.
- Impact: session A posted Command-V after session B replaced the clipboard, pasting B's text. Session B
  snapshotted A's transient text as the "original" and restored it, so the user's real clipboard was lost.
- Fix: sessions are chained on the main actor, so a session prepares the clipboard only after the
  previous one posted Command-V. A pending restore records its session ID and saved contents. A new
  session that finds the pasteboard still owned by that session inherits those contents, and the
  older restore stands down. Restore still requires ownership of text and session marker.
- Validation: parse-checked only. Needs a manual macOS check with two rapid pastes.

### 11. Word replacement templates interpreted `$` and `\` (Medium, fixed)
- File: `Voce/Features/Dictionary/Workflows/WordReplacementService.swift`
- Trigger: `stringByReplacingMatches(withTemplate: replacementText)`. NSRegularExpression templates treat
  `$n` as a capture reference and `\` as an escape.
- Impact: replacements like `C:\Users\me` or `$5 off` were silently altered in every transcript.
- Fix: `NSRegularExpression.escapedTemplate(for:)`.
- Validation: parse-checked only.

### 12. Screen capture timeout did not bound latency (Low, fixed)
- File: `Voce/Infrastructure/SystemIntegration/ScreenCapture/ScreenCaptureService.swift`
- Trigger: `withTaskGroup` waits for every child before returning. Vision OCR does not stop on cancel.
- Impact: the 3 second timeout returned only when OCR finished, delaying context capture.
- Fix: the operation runs unstructured, a one-shot gate resumes with the first result, timeout or
  caller cancellation, then cancels the losing operation.
- Validation: parse-checked only.

### 13. Auto Learn overlap check could hang the main actor on model output (Low, fixed)
- File: `Voce/Features/Dictionary/AutoLearn/AutoLearnAIReviewer.swift`
- Trigger: `canLocateWithoutOverlap` backtracks factorially over many short terms. The model chooses how
  many decisions it returns per candidate, and the reviewer is `@MainActor`.
- Fix: a 10,000-step budget. Past it, the decisions count as overlapping and the candidate stays
  unresolved, which is the existing conservative outcome.
- Validation: parse-checked only.

### 14. Web accessibility restore could record Sotto's own value (Low, fixed)
- File: `Voce/Features/Dictionary/AutoLearn/AutoLearnAXTextReader.swift`
- Trigger: a second enable before restore overwrote the saved original `AXManualAccessibility` value with `true`.
- Impact: Sotto could leave web accessibility forced on in a browser.
- Fix: the original value is recorded only once per process until restore.
- Validation: parse-checked only.

### 15. Local build never monitored the Quick Add and Quick History shortcuts (Medium, fixed)
- File: `Voce/Features/Shortcuts/Coordination/RecordingShortcutManager.swift`
- Trigger: shipped builds set `VOCE_LOCAL`, where the monitor started with an empty shortcut map plus Fn.
  Dictionary Settings and History Settings still let the user record these two shortcuts.
- Impact: the recorded shortcuts never fired.
- Fix: the local build monitors `openQuickHistory` and `quickAddToDictionary`. Shortcuts hidden in the
  local Settings UI (paste last, retry) stay unmonitored, so stale stored values do not reactivate.
- Validation: parse-checked only. If the omission was intended, revert this one hunk.

## Suggestions (not changed)
- Website triggers: the first enabled mode wins. With `google.com` in one mode and `mail.google.com` in
  another, the broader one can win by order. Preferring the most specific match would be clearer.
- `ShortcutMonitor` calls `CGSessionCopyCurrentDictionary` on every global key event. Caching it per
  run loop turn would reduce work inside the event tap.
- `ShortcutMonitor` logs every Fn flags change at notice level.
- `AppNotificationView` runs a 0.1 s repeating progress timer, a continuous repaint while a notification shows.
- Audio-only cleanup deletes the file before saving the nil URL. A failed save leaves a record pointing
  at a missing file. Harmless today, but inconsistent with the transcript path.

## Remaining and unverified risks
- No macOS compile or typecheck ran. Parse succeeds; actor isolation, Sendable checks and AppKit and
  SwiftData API usage in touched files are unverified until mac CI.
- `CursorPaster`: if `setClipboard` fails after inheriting a pending restore, the clipboard is already
  cleared and the original is lost (unchanged pre-existing behavior on that failure path).
- Cross-ownership: `RecordingContextCaptureService` (recording agent) reads the clipboard for context.
  During a pending restore it reads Sotto's own transcript instead of the user's clipboard.
- `LogExporter` uses `OSLogStore(scope: .system)`, which needs privileges the app may lack. Not changed.
- `AppDelegate.applicationShouldTerminate` waits on Dock restoration with no timeout (Dock code is
  outside this area).
- `RecorderPanelShortcutManager.visibilityTask` retains its owner strongly. Lifetime matches the app today.

## Tests added
- `Tests/AuditPersistence/SettingsValueLimitsTests.swift`
- `scripts/test-audit-persistence.sh` (uses `xcrun swiftc` on macOS, `swiftc` elsewhere). Not wired into CI;
  the parent owns wiring.
- Command run: `docker run --rm --network none --mount type=bind,src=$PWD,dst=/workspace,readonly
  --workdir /workspace -e TMPDIR=/tmp swift:6.2-bookworm bash scripts/test-audit-persistence.sh`
  -> `PASS: settings value limits`.
- All 23 touched Swift files passed `swiftc -frontend -parse -D VOCE_LOCAL -D ENABLE_NATIVE_SPEECH_ANALYZER`.

## Files changed by this agent
- New: `Voce/App/Configuration/SettingsValueLimits.swift`, `Voce/Features/Dictionary/AutoLearn/AutoLearnJSONArrayFile.swift`,
  `Voce/Features/Modes/State/ModeWebsiteMatcher.swift`, `Voce/Infrastructure/Persistence/Cleanup/RecordingFileLocation.swift`,
  `Tests/AuditPersistence/SettingsValueLimitsTests.swift`, `scripts/test-audit-persistence.sh`
- Modified: `Voce/App/Voce.swift`, `Voce/Features/Dashboard/State/DashboardStatsModels.swift`,
  `Voce/Features/Dashboard/Views/DashboardContent.swift`, `Voce/Features/Dictionary/AutoLearn/AutoLearnAIReviewer.swift`,
  `Voce/Features/Dictionary/AutoLearn/AutoLearnAXTextReader.swift`, `Voce/Features/Dictionary/AutoLearn/AutoLearnPendingQueue.swift`,
  `Voce/Features/Dictionary/AutoLearn/AutoLearnReviewProposalStore.swift`, `Voce/Features/Dictionary/Workflows/WordReplacementService.swift`,
  `Voce/Features/Modes/State/ModeConfig.swift`, `Voce/Features/Settings/Backup/BackupImporter.swift`,
  `Voce/Features/Settings/Backup/ImportExportService.swift`, `Voce/Features/Shortcuts/Coordination/RecordingShortcutManager.swift`,
  `Voce/Infrastructure/Persistence/Cleanup/AudioCleanupManager.swift`, `Voce/Infrastructure/Persistence/Cleanup/TranscriptionAutoCleanupService.swift`,
  `Voce/Infrastructure/Persistence/Statistics/DashboardStatsSnapshotStore.swift`, `Voce/Infrastructure/SystemIntegration/Media/MediaController.swift`,
  `Voce/Infrastructure/SystemIntegration/Paste/CursorPaster.swift`, `Voce/Infrastructure/SystemIntegration/ScreenCapture/ScreenCaptureService.swift`
- `Voce/App/Configuration/AppDefaults.swift` ends byte-identical to its start: the limits were added there, then moved out.

## Coverage: every file in the assigned zone (188)
"Read in full" means every line was read. "Pattern-scanned" means the file was searched for force
unwraps, casts, indexing, arithmetic conversions, persistence, timers, tasks and state mutation, and
any hits were read in context, but SwiftUI layout code was not read line by line. 66 files, mostly
SwiftUI views and design-system components, are in that last group and are a residual risk for
logic hidden in view code.

- `Voce/App/AppIntents/AppShortcuts.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/App/AppIntents/DismissMiniRecorderIntent.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/App/AppIntents/ToggleMiniRecorderIntent.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/App/Components/AppIconView.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/App/Configuration/AppAppearancePreference.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/App/Configuration/AppDefaults.swift`: read in full
- `Voce/App/Configuration/AppLanguagePreference.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/App/Configuration/AppStorageNamespace.swift`: read in full
- `Voce/App/Configuration/SettingsValueLimits.swift`: read in full
- `Voce/App/Lifecycle/AppDelegate.swift`: read in full
- `Voce/App/Lifecycle/ModelPrewarmService.swift`: read in full
- `Voce/App/MenuBar/MenuBarManager.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/App/MenuBar/MenuBarView.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/App/Migrations/OnboardingV2Migration.swift`: read in full
- `Voce/App/Migrations/RebrandMigration.swift`: read in full
- `Voce/App/Migrations/StreamingKeysMigration.swift`: read in full
- `Voce/App/Navigation/AppSidebar.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/App/Navigation/ContentView.swift`: logic sections read; layout code pattern-scanned
- `Voce/App/Notifications/AnnouncementManager.swift`: read in full
- `Voce/App/Notifications/AppNotifications.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/App/Notifications/NotificationManager.swift`: read in full
- `Voce/App/Notifications/Views/AnnouncementView.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/App/Notifications/Views/AppNotificationView.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/App/Voce.swift`: read in full
- `Voce/App/Windows/PersistentQuickPanel.swift`: logic sections read; layout code pattern-scanned
- `Voce/App/Windows/WindowManager.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Components/AddIconButton.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Components/AppControls.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Components/CompactHeroSection.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Components/CopyIconButton.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Components/ExpandableSettingsRow.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Components/InfoTip.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Components/MarkdownContentView.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Components/QuickPanelControls.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Layouts/FlowLayout.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Native/VisualEffectView.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Overlays/SidePanel.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Surfaces/AppSurfaces.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/DesignSystem/Theme/AppTheme.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Components/DashboardActivityCalendarCard.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Components/DashboardHeroCard.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Components/DashboardIconGlyph.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Components/DashboardInsightCardBackground.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Components/DashboardPeakHoursCard.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Components/DashboardTimeSavedCard.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Components/DashboardTranscriptCards.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Components/ModelInsightComponents.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Components/ModelInsightPanelComponents.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Components/ModelPerformanceCard.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Components/ModelProviderIcon.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Components/ModelUsageCard.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/State/DashboardStatsModels.swift`: logic sections read; layout code pattern-scanned
- `Voce/Features/Dashboard/Support/DashboardFormatters.swift`: logic sections read; layout code pattern-scanned
- `Voce/Features/Dashboard/Views/DashboardContent.swift`: logic sections read; layout code pattern-scanned
- `Voce/Features/Dashboard/Views/DashboardInsightsView.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Views/DashboardLayout.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Views/DashboardView.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Views/ModelPerformancePanel.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dashboard/Views/ModelUsagePanel.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Dictionary/AutoLearn/AutoLearnAIReviewer.swift`: read in full
- `Voce/Features/Dictionary/AutoLearn/AutoLearnAXRuntime.swift`: read in full
- `Voce/Features/Dictionary/AutoLearn/AutoLearnAXTextReader.swift`: read in full
- `Voce/Features/Dictionary/AutoLearn/AutoLearnFocusObserver.swift`: read in full
- `Voce/Features/Dictionary/AutoLearn/AutoLearnJSONArrayFile.swift`: read in full
- `Voce/Features/Dictionary/AutoLearn/AutoLearnPendingQueue.swift`: read in full
- `Voce/Features/Dictionary/AutoLearn/AutoLearnReviewProposalStore.swift`: read in full
- `Voce/Features/Dictionary/AutoLearn/AutoLearnService.swift`: read in full
- `Voce/Features/Dictionary/AutoLearn/AutoLearnTypes.swift`: read in full
- `Voce/Features/Dictionary/AutoLearn/CorrectionDiffEngine.swift`: read in full
- `Voce/Features/Dictionary/AutoLearn/FinalSnapshotDiffEngine.swift`: read in full
- `Voce/Features/Dictionary/AutoLearn/WordReplacementStore.swift`: read in full
- `Voce/Features/Dictionary/QuickAdd/DictionaryQuickAddPanel.swift`: read in full
- `Voce/Features/Dictionary/Views/AutoLearnFailurePanel.swift`: read in full
- `Voce/Features/Dictionary/Views/AutoLearnModelSelectionView.swift`: read in full
- `Voce/Features/Dictionary/Views/AutoLearnReviewPanel.swift`: read in full
- `Voce/Features/Dictionary/Views/DictionaryFilePanelService.swift`: read in full
- `Voce/Features/Dictionary/Views/DictionaryImportPreviewSheet.swift`: read in full
- `Voce/Features/Dictionary/Views/DictionaryPill.swift`: read in full
- `Voce/Features/Dictionary/Views/DictionarySettingsPanel.swift`: read in full
- `Voce/Features/Dictionary/Views/DictionarySettingsView.swift`: read in full
- `Voce/Features/Dictionary/Views/EditReplacementSheet.swift`: read in full
- `Voce/Features/Dictionary/Views/VocabularyView.swift`: read in full
- `Voce/Features/Dictionary/Views/WordReplacementView.swift`: read in full
- `Voce/Features/Dictionary/Workflows/CustomVocabularyService.swift`: read in full
- `Voce/Features/Dictionary/Workflows/DictionaryArchive.swift`: read in full
- `Voce/Features/Dictionary/Workflows/DictionaryImportExportService.swift`: read in full
- `Voce/Features/Dictionary/Workflows/DictionaryService.swift`: read in full
- `Voce/Features/Dictionary/Workflows/DictionarySortService.swift`: read in full
- `Voce/Features/Dictionary/Workflows/WordReplacementService.swift`: read in full
- `Voce/Features/Dictionary/Workflows/WordReplacementVariants.swift`: read in full
- `Voce/Features/Modes/Components/ModeViewComponents.swift`: logic sections read; layout code pattern-scanned
- `Voce/Features/Modes/Components/TriggerSelectionItems.swift`: read in full
- `Voce/Features/Modes/Components/TriggerTemplateRow.swift`: read in full
- `Voce/Features/Modes/Coordination/ModeSetupNavigator.swift`: read in full
- `Voce/Features/Modes/Models/CustomCommandTemplate.swift`: read in full
- `Voce/Features/Modes/Models/ModeIcon.swift`: read in full
- `Voce/Features/Modes/Models/ModeTriggerHelpers.swift`: read in full
- `Voce/Features/Modes/Models/ModeTriggerModels.swift`: read in full
- `Voce/Features/Modes/Models/ModeTriggerWordDetectionService.swift`: read in full
- `Voce/Features/Modes/State/EmojiManager.swift`: read in full
- `Voce/Features/Modes/State/ModeConfigDraft.swift`: read in full
- `Voce/Features/Modes/State/ModeConfig.swift`: read in full
- `Voce/Features/Modes/State/ModeFormWarmupStore.swift`: read in full
- `Voce/Features/Modes/State/ModeRuntimeConfiguration.swift`: read in full
- `Voce/Features/Modes/State/ModeValidator.swift`: read in full
- `Voce/Features/Modes/State/ModeWebsiteMatcher.swift`: read in full
- `Voce/Features/Modes/Templates/StarterModeFactory.swift`: read in full
- `Voce/Features/Modes/Templates/StarterModePromptSeeder.swift`: read in full
- `Voce/Features/Modes/Templates/StarterModeTemplate.swift`: read in full
- `Voce/Features/Modes/Templates/TriggerTemplateCatalog.swift`: read in full
- `Voce/Features/Modes/Views/ModeConfigEditorView.swift`: read in full
- `Voce/Features/Modes/Views/ModeConfigFormView.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Modes/Views/ModeIconPickerView.swift`: logic sections read; layout code pattern-scanned
- `Voce/Features/Modes/Views/ModePopover.swift`: read in full
- `Voce/Features/Modes/Views/ModeSettingsPanelView.swift`: logic sections read; layout code pattern-scanned
- `Voce/Features/Modes/Views/ModeSettingsQuickSwitchTip.swift`: read in full
- `Voce/Features/Modes/Views/ModeTriggerSection.swift`: read in full
- `Voce/Features/Modes/Views/ModeTriggerSelectionView.swift`: read in full
- `Voce/Features/Modes/Views/ModeView.swift`: read in full
- `Voce/Features/Modes/Views/TriggerGroupEditorView.swift`: read in full
- `Voce/Features/Modes/Views/TriggerPickerPopover.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Components/OnboardingExperienceCard.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Components/OnboardingExperienceIntroCard.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Components/OnboardingLockedTextEditor.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Components/OnboardingSections.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Components/OnboardingShortcutSetupView.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Components/OnboardingTranscriptionSetupCard.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Components/PermissionStepRow.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Components/TranscriptionModelDownloadCard.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Models/OnboardingExperienceModels.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/State/OnboardingCoordinator.swift`: read in full
- `Voce/Features/Onboarding/State/OnboardingFlowController.swift`: logic sections read; layout code pattern-scanned
- `Voce/Features/Onboarding/State/OnboardingPermissionController.swift`: logic sections read; layout code pattern-scanned
- `Voce/Features/Onboarding/State/OnboardingPermissionModels.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Views/OnboardingContextAwarenessScreen.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Views/OnboardingExperienceScreen.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Views/OnboardingMicrophoneScreen.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Views/OnboardingModelScreen.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Views/OnboardingPermissionsScreen.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Views/OnboardingTrustScreen.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Onboarding/Views/OnboardingView.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Settings/Backup/BackupImporter.swift`: read in full
- `Voce/Features/Settings/Backup/BackupTypes.swift`: read in full
- `Voce/Features/Settings/Backup/ImportExportService.swift`: read in full
- `Voce/Features/Settings/Diagnostics/SystemInfoService.swift`: logic sections read; layout code pattern-scanned
- `Voce/Features/Settings/FinishAndSendSettings.swift`: read in full
- `Voce/Features/Settings/Updates/UpdateCheck.swift`: read in full
- `Voce/Features/Settings/Views/DiagnosticsSettingsView.swift`: read in full
- `Voce/Features/Settings/Views/SettingsView.swift`: read in full
- `Voce/Features/Settings/Views/UpdateSettingsView.swift`: read in full
- `Voce/Features/Shortcuts/Coordination/ModeShortcutManager.swift`: read in full
- `Voce/Features/Shortcuts/Coordination/RecorderPanelShortcutManager.swift`: read in full
- `Voce/Features/Shortcuts/Coordination/RecordingShortcutManager.swift`: read in full
- `Voce/Features/Shortcuts/Coordination/ShortcutMonitor.swift`: read in full
- `Voce/Features/Shortcuts/Models/ShortcutAction.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Shortcuts/Models/Shortcut.swift`: read in full
- `Voce/Features/Shortcuts/State/ShortcutMigration.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Shortcuts/State/ShortcutStore.swift`: read in full
- `Voce/Features/Shortcuts/State/ShortcutValidator.swift`: read in full
- `Voce/Features/Shortcuts/Views/ShortcutPreviewView.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Features/Shortcuts/Views/ShortcutRecorder.swift`: pattern-scanned for crash, persistence, timing and state logic; layout code not read line by line
- `Voce/Infrastructure/Diagnostics/LogExporter.swift`: read in full
- `Voce/Infrastructure/Persistence/Cleanup/AudioCleanupManager.swift`: read in full
- `Voce/Infrastructure/Persistence/Cleanup/RecordingFileLocation.swift`: read in full
- `Voce/Infrastructure/Persistence/Cleanup/TranscriptionAutoCleanupService.swift`: read in full
- `Voce/Infrastructure/Persistence/Migrations/ModeDataMigration.swift`: read in full
- `Voce/Infrastructure/Persistence/Migrations/SessionMetricMigrationService.swift`: read in full
- `Voce/Infrastructure/Persistence/Models/SessionMetric.swift`: read in full
- `Voce/Infrastructure/Persistence/Models/Transcription.swift`: read in full
- `Voce/Infrastructure/Persistence/Models/VocabularyWord.swift`: read in full
- `Voce/Infrastructure/Persistence/Models/WordReplacement.swift`: read in full
- `Voce/Infrastructure/Persistence/Preferences/UserDefaultsManager.swift`: read in full
- `Voce/Infrastructure/Persistence/Statistics/DashboardStatsLoader.swift`: read in full
- `Voce/Infrastructure/Persistence/Statistics/DashboardStatsSnapshotStore.swift`: read in full
- `Voce/Infrastructure/Persistence/Statistics/EstimatedTokenCounter.swift`: read in full
- `Voce/Infrastructure/Persistence/Statistics/SessionMetricRecorder.swift`: read in full
- `Voce/Infrastructure/SystemIntegration/Accessibility/SelectedTextService.swift`: read in full
- `Voce/Infrastructure/SystemIntegration/Hardware/ClamshellStateMonitor.swift`: read in full
- `Voce/Infrastructure/SystemIntegration/Hardware/SystemArchitecture.swift`: read in full
- `Voce/Infrastructure/SystemIntegration/LaunchAtLoginManager.swift`: read in full
- `Voce/Infrastructure/SystemIntegration/Lifecycle/LifecycleObserver.swift`: read in full
- `Voce/Infrastructure/SystemIntegration/Lifecycle/UserSessionInputPolicy.swift`: read in full
- `Voce/Infrastructure/SystemIntegration/Media/MediaController.swift`: read in full
- `Voce/Infrastructure/SystemIntegration/Media/PlaybackController.swift`: read in full
- `Voce/Infrastructure/SystemIntegration/Paste/ClipboardManager.swift`: read in full
- `Voce/Infrastructure/SystemIntegration/Paste/CursorPaster.swift`: read in full
- `Voce/Infrastructure/SystemIntegration/Paste/PasteMethod.swift`: read in full
- `Voce/Infrastructure/SystemIntegration/ScreenCapture/ScreenCaptureService.swift`: read in full
