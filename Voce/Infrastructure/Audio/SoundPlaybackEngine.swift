@preconcurrency import AVFoundation
import Foundation
import os

/// Preloads dictation cues and confines all AVAudioPlayer state to a serial queue.
final class SoundPlaybackEngine: @unchecked Sendable {
    private enum Sound {
        case start
        case stop
        case esc
    }

    private let queue = DispatchQueue(label: "ro.andrei.Voce.soundPlayback", qos: .userInitiated)
    private let logger = Logger(subsystem: "ro.andrei.Voce", category: "SoundPlaybackEngine")

    private var startSound: AVAudioPlayer?
    private var stopSound: AVAudioPlayer?
    private var escSound: AVAudioPlayer?
    private var customStartSound: AVAudioPlayer?
    private var customStopSound: AVAudioPlayer?
    private var volume: Float = 0.3

    func setup(
        defaultStartURL: URL?,
        defaultStopURL: URL?,
        defaultEscURL: URL?,
        customStartURL: URL?,
        customStopURL: URL?,
        volume: Float = 0.3
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopPlayersOnQueue()
            self.volume = Self.clampedVolume(volume)
            self.startSound = self.makePlayer(from: defaultStartURL, volume: self.volume)
            self.stopSound = self.makePlayer(from: defaultStopURL, volume: self.volume)
            self.escSound = self.makePlayer(from: defaultEscURL, volume: self.volume * (2 / 3))
            self.reloadCustomSoundsOnQueue(startURL: customStartURL, stopURL: customStopURL)
        }
    }

    /// Update gain on the playback queue; zero immediately silences any active cue.
    func setVolume(_ volume: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            self.volume = Self.clampedVolume(volume)
            for player in [self.startSound, self.stopSound, self.customStartSound, self.customStopSound] {
                player?.volume = self.volume
            }
            self.escSound?.volume = self.volume * (2 / 3)
            if self.volume == 0 { self.stopPlayersOnQueue() }
        }
    }

    private static func clampedVolume(_ volume: Float) -> Float {
        volume.isFinite ? min(1, max(0, volume)) : 0
    }

    private func stopPlayersOnQueue() {
        for player in [startSound, stopSound, escSound, customStartSound, customStopSound] {
            player?.stop()
        }
    }

    func reloadCustomSounds(startURL: URL?, stopURL: URL?) {
        queue.async { [weak self] in
            self?.reloadCustomSoundsOnQueue(startURL: startURL, stopURL: stopURL)
        }
    }

    func playStartSound() {
        play(.start)
    }

    func playStopSound() {
        play(.stop)
    }

    func playEscSound() {
        play(.esc)
    }

    private func reloadCustomSoundsOnQueue(startURL: URL?, stopURL: URL?) {
        if customStartSound?.isPlaying == true {
            customStartSound?.stop()
        }
        if customStopSound?.isPlaying == true {
            customStopSound?.stop()
        }

        customStartSound = makePlayer(from: startURL, volume: volume)
        customStopSound = makePlayer(from: stopURL, volume: volume)
    }

    private func play(_ sound: Sound) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.volume > 0 else { return }

            let player: AVAudioPlayer?
            switch sound {
            case .start:
                player = self.customStartSound ?? self.startSound
            case .stop:
                player = self.customStopSound ?? self.stopSound
            case .esc:
                player = self.escSound
            }

            player?.play()
        }
    }

    private func makePlayer(from url: URL?, volume: Float) -> AVAudioPlayer? {
        guard let url else { return nil }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = volume
            player.prepareToPlay()
            return player
        } catch {
            logger.error("Failed to load sound: \(error, privacy: .public)")
            return nil
        }
    }
}
