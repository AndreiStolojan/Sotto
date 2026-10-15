import SwiftUI

struct AudioVisualizer: View {
    let audioMeterProvider: () -> AudioMeter
    let color: Color
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var amplitude: Double = 0

    #if VOCE_LOCAL
    private let minHeight: CGFloat = 2.5
    private let maxHeight: CGFloat = 24
    private let barSpacing: CGFloat = 2.5
    private let barWidth: CGFloat = 2.5
    #else
    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 28
    private let barSpacing: CGFloat = 2
    private let barWidth: CGFloat = 3
    #endif

    /// A flattened envelope: twelve bars, the edges nearly as tall as the center (1 - d² / 90).
    static let shape: [Double] = (0..<12).map { index in
        let distance = Double(index) - 5.5
        return 1 - distance * distance / 90
    }

    init(audioMeterProvider: @escaping () -> AudioMeter, color: Color, isActive: Bool) {
        self.audioMeterProvider = audioMeterProvider
        self.color = color
        self.isActive = isActive
    }

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(Self.shape.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color.opacity(0.85))
                    .frame(width: barWidth, height: barHeight(for: index))
            }
        }
        .frame(height: maxHeight)
        .transaction { $0.disablesAnimations = true }
        .task(id: isActive) {
            guard isActive else {
                amplitude = 0
                return
            }

            // Recorder already smooths microphone power. Poll only while visible and active.
            while !Task.isCancelled {
                let power = max(0, min(1, audioMeterProvider().averagePower))
                let nextAmplitude = (pow(power, 0.7) * 100).rounded() / 100
                if nextAmplitude != amplitude {
                    amplitude = nextAmplitude
                }
                do {
                    try await Task.sleep(nanoseconds: reduceMotion ? 100_000_000 : 50_000_000)
                } catch {
                    return
                }
            }
        }
    }

    /// The fixed envelope grows with real audio, without synthetic movement. Inactive bars rest as dots.
    private func barHeight(for index: Int) -> CGFloat {
        guard isActive else { return minHeight }
        return minHeight + CGFloat(amplitude * Self.shape[index]) * (maxHeight - minHeight)
    }
}

// Flat bars shown when the recorder is idle (no audio input)
struct StaticVisualizer: View {
    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let barHeight: CGFloat = 4
    private let barSpacing: CGFloat = 2
    let color: Color

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color.opacity(0.5))
                    .frame(width: barWidth, height: barHeight)
            }
        }
    }
}

// MARK: - Processing Status Display

struct ProcessingStatusDisplay: View {
    enum Mode {
        case transcribing
        case enhancing
    }

    let mode: Mode
    let color: Color

    private var label: LocalizedStringKey {
        switch mode {
        case .transcribing: return "Transcribing"
        case .enhancing: return "Enhancing"
        }
    }

    private var animationSpeed: Double {
        switch mode {
        case .transcribing: return 0.18
        case .enhancing: return 0.22
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .foregroundColor(color)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            ProgressAnimation(color: color, animationSpeed: animationSpeed)
        }
        .frame(height: 28)  // matches AudioVisualizer maxHeight to prevent layout shift
    }
}
