import SwiftUI

/// Gives circular recorder controls pressed feedback without a rectangular system highlight.
struct CircularRecorderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(.focusEffect, Circle())
    }
}
