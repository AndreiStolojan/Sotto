import Foundation
import SwiftUI

@MainActor
class SoundManager: ObservableObject {
    static let shared = SoundManager()

    private let playbackEngine = SoundPlaybackEngine()

    private init() {
        setupSounds()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadCustomSounds),
            name: NSNotification.Name("CustomSoundsChanged"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateSoundVolume),
            name: NSNotification.Name("RecordingSoundVolumeChanged"),
            object: nil
        )
    }

    private func setupSounds() {
        let customSoundManager = CustomSoundManager.shared
        playbackEngine.setup(
            defaultStartURL: customSoundManager.builtInSoundURL(for: .start),
            defaultStopURL: customSoundManager.builtInSoundURL(for: .stop),
            defaultEscURL: CustomSoundManager.BuiltInSound.sound7.bundleURL,
            customStartURL: customSoundManager.getCustomSoundURL(for: .start),
            customStopURL: customSoundManager.getCustomSoundURL(for: .stop),
            volume: Float(customSoundManager.recordingSoundVolume)
        )
    }

    @objc private func reloadCustomSounds() {
        setupSounds()
    }

    @objc private func updateSoundVolume() {
        playbackEngine.setVolume(Float(CustomSoundManager.shared.recordingSoundVolume))
    }

    func playStartSound() {
        guard CustomSoundManager.shared.isSoundEnabled(for: .start) else { return }
        playbackEngine.playStartSound()
    }

    func playStopSound() {
        guard CustomSoundManager.shared.isSoundEnabled(for: .stop) else { return }
        playbackEngine.playStopSound()
    }

    func playEscSound() {
        guard CustomSoundManager.shared.hasAnyRecordingSoundEnabled else { return }
        playbackEngine.playEscSound()
    }
}
