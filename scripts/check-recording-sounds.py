#!/usr/bin/env python3
"""Exercise real macOS sound preferences, migration and AVAudioPlayer gain in isolation."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / 'Voce/Infrastructure/Audio/SoundPlaybackEngine.swift'
MANAGER = ROOT / 'Voce/Infrastructure/Audio/CustomSoundManager.swift'

PROBE = '''
extension SoundPlaybackEngine {
    // Same-file access keeps test inspection off the production API.
    func checkedVolumes() -> [Float] {
        queue.sync { [startSound, stopSound, escSound, customStartSound, customStopSound].compactMap { $0?.volume } }
    }
    func hasPlayingCue() -> Bool {
        queue.sync { [startSound, stopSound, escSound, customStartSound, customStopSound].contains { $0?.isPlaying == true } }
    }
}
'''

HARNESS = '''
import Foundation
struct AppStorageNamespace { static let applicationSupportDirectoryName = ".voce-sound-checks" }
@main struct Checks {
    @MainActor static func main() throws {
        let defaults = UserDefaults.standard
        let domain = ProcessInfo.processInfo.processName
        let scenario = CommandLine.arguments[1]
        if scenario != "persisted" { defaults.removePersistentDomain(forName: domain) }
        defer {
            if scenario != "migration" { defaults.removePersistentDomain(forName: domain) }
        }
        switch scenario {
        case "muted":
            defaults.set(false, forKey: "isSoundFeedbackEnabled")
        case "custom":
            defaults.set("custom", forKey: "selectedStartSoundSelection")
            defaults.set("chosen.wav", forKey: "customStartSoundFilename")
            defaults.set("none", forKey: "selectedStopSoundSelection")
        case "migration":
            defaults.set("sound5", forKey: "selectedStartBuiltInSound")
            defaults.set("sound6", forKey: "selectedStopBuiltInSound")
        default: break
        }
        let manager = CustomSoundManager.shared
        switch scenario {
        case "muted": precondition(!manager.hasAnyRecordingSoundEnabled)
        case "custom":
            precondition(manager.soundSelection(for: .start) == .custom("chosen.wav"))
            precondition(manager.soundSelection(for: .stop) == .none)
        case "persisted":
            precondition(manager.soundSelection(for: .start) == .builtIn(.sound5))
            precondition(manager.recordingSoundVolume == 0.12)
        default:
            precondition(manager.soundSelection(for: .start) == .builtIn(.featherStart))
            precondition(manager.soundSelection(for: .stop) == .builtIn(.featherStop))
        }
        manager.setRecordingSoundVolume(2)
        precondition(manager.recordingSoundVolume == 1)
        manager.setRecordingSoundVolume(-1)
        precondition(manager.recordingSoundVolume == 0)
        manager.setRecordingSoundVolume(.nan)
        precondition(manager.recordingSoundVolume == 0)
        manager.setRecordingSoundVolume(0.12)
        precondition(defaults.double(forKey: "recordingSoundVolume") == 0.12)
        manager.selectNoSound(for: .start)
        precondition(!manager.isSoundEnabled(for: .start))
        manager.selectBuiltInSound(.sound5, for: .start)
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        let engine = SoundPlaybackEngine()
        engine.setup(defaultStartURL: url, defaultStopURL: url, defaultEscURL: url,
                     customStartURL: url, customStopURL: url, volume: 0.12)
        let volumes = engine.checkedVolumes()
        precondition(volumes.count == 5)
        precondition(abs(volumes[0] - 0.12) < 0.001 && abs(volumes[2] - 0.08) < 0.001)
        engine.setVolume(0.6)
        precondition(engine.checkedVolumes().enumerated().allSatisfy { abs($0.element - ($0.offset == 2 ? 0.4 : 0.6)) < 0.001 })
        engine.playStartSound()
        engine.setVolume(0)
        precondition(engine.checkedVolumes().allSatisfy { $0 == 0 })
        precondition(!engine.hasPlayingCue())
        engine.playStartSound(); engine.playStopSound(); engine.playEscSound()
        precondition(!engine.hasPlayingCue())
        print("PASS \\(scenario): preferences, gain, zero-volume stop and mute")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='voce-sound-checks-') as directory:
    scratch = Path(directory)
    engine = scratch / 'Engine.swift'
    engine.write_text(ENGINE.read_text() + PROBE)
    harness = scratch / 'Checks.swift'
    harness.write_text(HARNESS)
    executable = scratch / ('VoceSoundChecks' + scratch.name.replace('-', ''))
    subprocess.run(['swiftc', '-D', 'VOCE_LOCAL', str(engine), str(MANAGER), str(harness), '-o', str(executable)], check=True)
    for scenario in ('migration', 'persisted', 'muted', 'custom', 'fresh'):
        subprocess.run([str(executable), scenario, str(ROOT / 'Voce/Resources/Sounds/feather-start.wav')], check=True)
