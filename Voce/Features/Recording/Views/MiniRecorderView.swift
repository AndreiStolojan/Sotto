import SwiftUI

struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Layout Constants

    private let controlBarHeight: CGFloat = 40
    #if VOCE_LOCAL
    private let compactWidth: CGFloat = 84
    private let compactCornerRadius: CGFloat = 16
    #else
    private let compactWidth: CGFloat = 184
    private let compactCornerRadius: CGFloat = 20
    #endif
    private let expandedWidth: CGFloat = 300
    private let assistantWidth: CGFloat = 520
    private let expandedCornerRadius: CGFloat = 14

    // true when live transcript is streaming in during recording
    private var hasLiveTranscript: Bool {
        showLiveTranscript
            && stateProvider.recordingState == .recording
            && !stateProvider.partialTranscript.isEmpty
    }

    private var hasAssistantResponse: Bool {
        assistantSession.isVisible
    }

    private var shouldShowCloseButton: Bool {
        hasAssistantResponse && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    private var controlBar: some View {
        HStack(spacing: 0) {
            Group {
                if shouldShowCloseButton {
                    RecorderCloseButton(action: onCloseTapped)
                } else {
                    RecorderRecordButton(
                        recordingState: stateProvider.recordingState,
                        action: onRecordButtonTapped
                    )
                }
            }
            .padding(.leading, 10)

            Spacer(minLength: 0)

            RecorderStatusDisplay(
                currentState: stateProvider.recordingState,
                audioMeterProvider: recorder.audioMeterSnapshot
            )

            Spacer(minLength: 0)

            RecorderModeButton(
                buttonSize: 22,
                padding: EdgeInsets()
            )
            .padding(.trailing, 12)
        }
        .frame(height: controlBarHeight)
    }

    #if VOCE_LOCAL
    /// The compact pill shows only audio bars, no controls; recording runs from the shortcut.
    private var ribbonControlBar: some View {
        ribbonStatus
            .frame(maxWidth: .infinity)
            .frame(height: 32)
    }

    @ViewBuilder
    private var ribbonStatus: some View {
        switch stateProvider.recordingState {
        case .transcribing, .enhancing:
            Text("···")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .accessibilityLabel(stateProvider.recordingState == .transcribing ? "Transcribing" : "Enhancing")
        case .recording, .idle, .starting, .busy:
            // Idle bars rest as dimmed dots; the same view keeps the layout identical.
            AudioVisualizer(
                audioMeterProvider: recorder.audioMeterSnapshot,
                color: stateProvider.recordingState == .recording ? .white : .white.opacity(0.6),
                isActive: stateProvider.recordingState == .recording
            )
        }
    }
    #endif

    private var transcriptSection: some View {
        VStack(spacing: 0) {
            if hasLiveTranscript {
                LiveTranscriptView(text: stateProvider.partialTranscript)
                Divider().background(Color.white.opacity(0.15))
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasAssistantResponse {
                AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp
                )
                Divider().background(Color.white.opacity(0.15))
            } else {
                transcriptSection
            }
            #if VOCE_LOCAL
            if hasLiveTranscript || hasAssistantResponse {
                controlBar
            } else {
                ribbonControlBar
            }
            #else
            controlBar
            #endif
        }
        .frame(width: hasAssistantResponse ? assistantWidth : (hasLiveTranscript ? expandedWidth : compactWidth))
        .background(Color.black)
        .clipShape(
            RoundedRectangle(
                cornerRadius: hasLiveTranscript || hasAssistantResponse ? expandedCornerRadius : compactCornerRadius,
                style: .continuous)
        )
        #if VOCE_LOCAL
        .overlay {
            if !hasLiveTranscript && !hasAssistantResponse {
                RoundedRectangle(cornerRadius: compactCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        #endif
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: hasLiveTranscript)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: hasAssistantResponse)
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
