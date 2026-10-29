# Parent integration and coverage supplement

This supplements the agents' reports. The parent read the 66 pattern-scanned
files and the 11 files whose logic sections alone had been read in the
persistence report. All 77 paths below were read, including their view actions,
state changes, timers and layout declarations. This closes that report's source
coverage gap; it does not prove the UI works on macOS.

## Additional repairs

- Low: `CopyIconButton` showed a success tick even when copying failed. It now
  acknowledges only a successful clipboard write.
- Medium: `ShortcutRecorder` rendered only the primary Fn label under
  `VOCE_LOCAL`, hiding the editor for Quick History and Dictionary shortcuts.
  The existing editor is restored for utility actions; secondary recording stays
  hidden, so the Fn recording policy is unchanged. This completes the matching
  monitor repair from the persistence agent.
- Low: diagnostics decoded a C string after unchecked `sysctlbyname` calls.
  A missing property or a failed size query could leave an empty buffer. Reads
  now check both calls, bound allocation, and keep a terminating byte. Failure
  uses the existing `Unknown` fallback.
- Medium: failed paste preparation could discard an inherited original
  clipboard snapshot. With restoration enabled, the failure path now attempts
  to restore that snapshot immediately. OS clipboard write failures remain
  best-effort; no application can guarantee that an OS write succeeds.
- Medium: recording context capture could read Sotto's transient paste payload
  instead of the user's clipboard. Pending restore contents now become available
  immediately after clipboard preparation, and context reads use those original
  contents while Sotto owns the pasteboard. Outside a restore session, context
  reads the current clipboard as before.
- Medium: waveform and import code converted the full audio frame count to
  UInt32 before limiting it to the read buffer. Very long files could trap.
  Frame positions now stay wide until the bounded read size is converted.
  Waveforms also reject nonpositive sample counts and cache by requested count.

These macOS paths were reviewed statically. Native compilation and device tests
are explicitly unexecuted at the user's request. The final source syntax check
covers them, but cannot resolve AppKit or AVFoundation APIs on Linux.

## Corrected findings and deferred work

The persistence report says Dock restoration has no timeout. Inspection of
`DockVisibilityController.restoreBeforeTermination(timeout:)` shows a default
10-second deadline. The caller uses that default, so this is not an outstanding
unbounded-quit defect.

Onboarding text still says there are no update checks, although Settings now
supports a manual check. The context-awareness screen also has a continuously
rotating decorative border. These are recorded as copy/design follow-ups. This
audit does not change their design without the required mockup selection.

Dashboard duration formatters assume finite metrics. The metric ingestion paths
should continue to normalize durations before display. Extreme corrupted
numeric data remains a robustness risk, not a reproduced normal-use failure.

## Files read to close the coverage gap

- `Voce/App/AppIntents/AppShortcuts.swift`
- `Voce/App/AppIntents/DismissMiniRecorderIntent.swift`
- `Voce/App/AppIntents/ToggleMiniRecorderIntent.swift`
- `Voce/App/Components/AppIconView.swift`
- `Voce/App/Configuration/AppAppearancePreference.swift`
- `Voce/App/Configuration/AppLanguagePreference.swift`
- `Voce/App/MenuBar/MenuBarManager.swift`
- `Voce/App/MenuBar/MenuBarView.swift`
- `Voce/App/Navigation/AppSidebar.swift`
- `Voce/App/Navigation/ContentView.swift`
- `Voce/App/Notifications/AppNotifications.swift`
- `Voce/App/Notifications/Views/AnnouncementView.swift`
- `Voce/App/Notifications/Views/AppNotificationView.swift`
- `Voce/App/Windows/PersistentQuickPanel.swift`
- `Voce/App/Windows/WindowManager.swift`
- `Voce/DesignSystem/Components/AddIconButton.swift`
- `Voce/DesignSystem/Components/AppControls.swift`
- `Voce/DesignSystem/Components/CompactHeroSection.swift`
- `Voce/DesignSystem/Components/CopyIconButton.swift`
- `Voce/DesignSystem/Components/ExpandableSettingsRow.swift`
- `Voce/DesignSystem/Components/InfoTip.swift`
- `Voce/DesignSystem/Components/MarkdownContentView.swift`
- `Voce/DesignSystem/Components/QuickPanelControls.swift`
- `Voce/DesignSystem/Layouts/FlowLayout.swift`
- `Voce/DesignSystem/Native/VisualEffectView.swift`
- `Voce/DesignSystem/Overlays/SidePanel.swift`
- `Voce/DesignSystem/Surfaces/AppSurfaces.swift`
- `Voce/DesignSystem/Theme/AppTheme.swift`
- `Voce/Features/Dashboard/Components/DashboardActivityCalendarCard.swift`
- `Voce/Features/Dashboard/Components/DashboardHeroCard.swift`
- `Voce/Features/Dashboard/Components/DashboardIconGlyph.swift`
- `Voce/Features/Dashboard/Components/DashboardInsightCardBackground.swift`
- `Voce/Features/Dashboard/Components/DashboardPeakHoursCard.swift`
- `Voce/Features/Dashboard/Components/DashboardTimeSavedCard.swift`
- `Voce/Features/Dashboard/Components/DashboardTranscriptCards.swift`
- `Voce/Features/Dashboard/Components/ModelInsightComponents.swift`
- `Voce/Features/Dashboard/Components/ModelInsightPanelComponents.swift`
- `Voce/Features/Dashboard/Components/ModelPerformanceCard.swift`
- `Voce/Features/Dashboard/Components/ModelProviderIcon.swift`
- `Voce/Features/Dashboard/Components/ModelUsageCard.swift`
- `Voce/Features/Dashboard/State/DashboardStatsModels.swift`
- `Voce/Features/Dashboard/Support/DashboardFormatters.swift`
- `Voce/Features/Dashboard/Views/DashboardContent.swift`
- `Voce/Features/Dashboard/Views/DashboardInsightsView.swift`
- `Voce/Features/Dashboard/Views/DashboardLayout.swift`
- `Voce/Features/Dashboard/Views/DashboardView.swift`
- `Voce/Features/Dashboard/Views/ModelPerformancePanel.swift`
- `Voce/Features/Dashboard/Views/ModelUsagePanel.swift`
- `Voce/Features/Modes/Components/ModeViewComponents.swift`
- `Voce/Features/Modes/Views/ModeConfigFormView.swift`
- `Voce/Features/Modes/Views/ModeIconPickerView.swift`
- `Voce/Features/Modes/Views/ModeSettingsPanelView.swift`
- `Voce/Features/Modes/Views/TriggerPickerPopover.swift`
- `Voce/Features/Onboarding/Components/OnboardingExperienceCard.swift`
- `Voce/Features/Onboarding/Components/OnboardingExperienceIntroCard.swift`
- `Voce/Features/Onboarding/Components/OnboardingLockedTextEditor.swift`
- `Voce/Features/Onboarding/Components/OnboardingSections.swift`
- `Voce/Features/Onboarding/Components/OnboardingShortcutSetupView.swift`
- `Voce/Features/Onboarding/Components/OnboardingTranscriptionSetupCard.swift`
- `Voce/Features/Onboarding/Components/PermissionStepRow.swift`
- `Voce/Features/Onboarding/Components/TranscriptionModelDownloadCard.swift`
- `Voce/Features/Onboarding/Models/OnboardingExperienceModels.swift`
- `Voce/Features/Onboarding/State/OnboardingFlowController.swift`
- `Voce/Features/Onboarding/State/OnboardingPermissionController.swift`
- `Voce/Features/Onboarding/State/OnboardingPermissionModels.swift`
- `Voce/Features/Onboarding/Views/OnboardingContextAwarenessScreen.swift`
- `Voce/Features/Onboarding/Views/OnboardingExperienceScreen.swift`
- `Voce/Features/Onboarding/Views/OnboardingMicrophoneScreen.swift`
- `Voce/Features/Onboarding/Views/OnboardingModelScreen.swift`
- `Voce/Features/Onboarding/Views/OnboardingPermissionsScreen.swift`
- `Voce/Features/Onboarding/Views/OnboardingTrustScreen.swift`
- `Voce/Features/Onboarding/Views/OnboardingView.swift`
- `Voce/Features/Settings/Diagnostics/SystemInfoService.swift`
- `Voce/Features/Shortcuts/Models/ShortcutAction.swift`
- `Voce/Features/Shortcuts/State/ShortcutMigration.swift`
- `Voce/Features/Shortcuts/Views/ShortcutPreviewView.swift`
- `Voce/Features/Shortcuts/Views/ShortcutRecorder.swift`
