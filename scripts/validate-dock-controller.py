#!/usr/bin/env python3
"""Validate the production Dock controller and state binding with a simulated OS backend."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
s=(root/'Voce/Features/Recording/Presentation/DockVisibilityController.swift').read_text()
s=s.replace('private let defaults = UserDefaults.standard','private let defaults = Harness.defaults')
a=s.index('    private var isAutoHidden: Bool {');b=s.index('    @objc private func applicationWillTerminate()',a)
s=s[:a]+'''    private var isAutoHidden: Bool { Harness.backend.hidden }
    private func toggleAutoHide() -> Bool { Harness.backend.toggle() }

'''+s[b:]
ui = (root / 'Voce/Features/Recording/Presentation/RecorderUIManager.swift').read_text()
binding_start = ui.index('        dockRecordingCancellable = engine.$recordingState')
binding_end = ui.index('        #endif', binding_start)
# Stop before the Eclipse wiring; the harness runs without Eclipse.
extra = ui.find('        notchReplacementCancellable = ', binding_start, binding_end)
binding = ui[binding_start:binding_end if extra < 0 else extra]
state = (root / 'Voce/Core/Recording/RecordingState.swift').read_text()
pre='''import Foundation
import Combine
@MainActor enum Harness {
 static var defaults=UserDefaults(suiteName:"ro.andrei.Voce.DockValidation."+UUID().uuidString)!
 static var backend=Backend()
 static let key="VoceDockAutohideNeedsRestore"
 static func prepare(hidden:Bool=false, delay:UInt64=0, marker:Bool=false) {
  defaults=UserDefaults(suiteName:"ro.andrei.Voce.DockValidation."+UUID().uuidString)!
  backend=Backend(); backend.hidden=hidden; backend.delay=delay
  defaults.set(marker,forKey:key)
 }
 static var marker:Bool { defaults.bool(forKey:key) }
 static var pending:Bool? { defaults.object(forKey:"VoceDockAutohidePendingTarget") as? Bool }
}
@MainActor final class Backend {
 var hidden=false; var delay:UInt64=0; var toggles=0; var applies=true; var available=true; var drop=0
 func toggle() -> Bool {
  guard available else { return false }
  toggles += 1
  if drop > 0 { drop -= 1; return true }
  guard applies else { return true }
  if delay == 0 { hidden.toggle() }
  else { let wait=delay; Task { @MainActor in try? await Task.sleep(nanoseconds:wait); self.hidden.toggle() } }
  return true
 }
}
'''
pre += state + '''
enum RecorderPanelStyle { case notch, mini }
@MainActor final class EngineHarness: ObservableObject {
 @Published var recordingState: RecordingState = .idle
}
@MainActor final class DockBindingHarness {
 private let dockVisibility = DockVisibilityController()
 private var dockRecordingCancellable: AnyCancellable?
 @Published var recorderPanelStyle = RecorderPanelStyle.mini
 @Published var hidesDockWhileRecording = true
 init(engine: EngineHarness) {
  let notchReplacement = Just(false)
''' + binding + '''
 }
}
'''
# Exercise the actual quit callback with a test application whose reply cannot terminate the harness.
delegate = (root / "Voce/App/Lifecycle/AppDelegate.swift").read_text()
quit_code = delegate[delegate.index("    weak var dockVisibility"):delegate.index("    func applicationDidFinishLaunching")].replace("    #endif\n", "")
pre += "\n@MainActor final class QuitDelegate {\n" + quit_code + "\n}\n"
pre += '''
@MainActor final class TestApplication: NSApplication {
 var replies=0
 override func reply(toApplicationShouldTerminate shouldTerminate:Bool) {
  precondition(shouldTerminate)
  replies += 1
 }
}
'''
probe='''
@main struct Probe {
 @MainActor static func main() async {
  var failures=0
  func check(_ name:String,_ good:Bool) {
   print(good ? "PASS" : "FAIL",name,"hidden",Harness.backend.hidden,"toggles",Harness.backend.toggles,"marker",Harness.marker)
   if !good { failures += 1 }
  }
  func wait(_ ns:UInt64=100_000_000) async { try? await Task.sleep(nanoseconds:ns) }
  func settled(_ predicate:() -> Bool, timeout:Duration = .seconds(2)) async {
   let clock=ContinuousClock(); let deadline=clock.now.advanced(by:timeout)
   while !predicate(), clock.now < deadline { await wait(20_000_000) }
  }
  // Every scenario retains its controller until its pending simulated events have settled.
  func initialVisible() async {
   Harness.prepare(); let c=DockVisibilityController(); c.hideForRecording()
   await settled { Harness.backend.hidden }
   check("initial visible hide",Harness.backend.hidden && Harness.marker && Harness.backend.toggles == 1)
   c.restore(); await settled { !Harness.marker }
   check("initial visible restore",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 2)
  }
  func alreadyHidden() async {
   Harness.prepare(hidden:true); let c=DockVisibilityController(); c.hideForRecording(); await wait()
   await c.restoreBeforeTermination()
   check("already hidden preserved through quit",Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 0)
  }
  func repeatedStarts() async {
   Harness.prepare(); let c=DockVisibilityController(); c.hideForRecording(); c.hideForRecording()
   await settled { Harness.backend.hidden }; c.hideForRecording(); await wait()
   check("repeated starts never toggle twice",Harness.backend.hidden && Harness.backend.toggles == 1)
   c.restore(); c.restore(); await settled { !Harness.marker }
   check("repeated restores never toggle twice",!Harness.backend.hidden && Harness.backend.toggles == 2)
  }
  func stopInflight() async {
   Harness.prepare(delay:300_000_000); let c=DockVisibilityController(); c.hideForRecording()
   await wait(20_000_000); c.restore(); await settled { !Harness.marker }
   check("stop during startup restores",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 2)
  }
  func normalQuit() async {
   Harness.prepare(); let c=DockVisibilityController(); c.hideForRecording(); await settled { Harness.backend.hidden }
   await c.restoreBeforeTermination(); _=c.perform(NSSelectorFromString("applicationWillTerminate"))
   check("normal quit confirms restoration",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 2)
  }
  func quitDuringRestore() async {
   Harness.prepare(); let c=DockVisibilityController(); c.hideForRecording(); await settled { Harness.backend.hidden }
   Harness.backend.delay=300_000_000; c.restore(); await wait(20_000_000)
   await c.restoreBeforeTermination(); _=c.perform(NSSelectorFromString("applicationWillTerminate")); await wait(350_000_000)
   check("quit while restore pending posts no duplicate",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 2)
  }
  func quitDuringHide() async {
   Harness.prepare(delay:300_000_000); let c=DockVisibilityController(); c.hideForRecording(); await wait(20_000_000)
   await c.restoreBeforeTermination(); _=c.perform(NSSelectorFromString("applicationWillTerminate"))
   check("quit while hide pending waits then restores",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 2)
  }
  func recoverHiddenMarker() async {
   Harness.prepare(hidden:true,marker:true); let c=DockVisibilityController(); await settled { !Harness.marker }
   check("launch recovers marked hidden Dock",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 1)
   withExtendedLifetime(c) {}
   Harness.prepare(marker:true); let next=DockVisibilityController(); await settled { !Harness.marker }
   check("launch clears already restored marker",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 0)
   withExtendedLifetime(next) {}
  }
  func lostFirstPost() async {
   Harness.prepare(); Harness.backend.drop=1; let c=DockVisibilityController(); c.hideForRecording()
   await settled({ Harness.backend.hidden }, timeout:.seconds(3))
   check("lost first post is retried once",Harness.backend.hidden && Harness.marker && Harness.backend.toggles == 2)
   c.restore(); await settled { !Harness.marker }
   check("retried hide still restores",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 3)
  }
  func ignoredHide() async {
   // A fullscreen Space keeps the Dock hidden and the Dock ignores the shortcut entirely.
   Harness.prepare(); Harness.backend.applies=false; let c=DockVisibilityController(); c.hideForRecording()
   await settled({ Harness.backend.toggles == 2 }, timeout:.seconds(5)); await settled({ !Harness.marker }, timeout:.seconds(5))
   check("ignored hide gives up without owning the preference",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 2)
   c.restore(); await wait()
   check("stop after ignored hide posts nothing",Harness.backend.toggles == 2)
   Harness.backend.applies=true; c.hideForRecording(); await settled { Harness.backend.hidden }
   check("next recording hides again",Harness.backend.hidden && Harness.marker && Harness.backend.toggles == 3)
   c.restore(); await settled { !Harness.marker }
   check("next recording restores again",!Harness.backend.hidden && Harness.backend.toggles == 4)
  }
  func ignoredRestore() async {
   Harness.prepare(); let c=DockVisibilityController(); c.hideForRecording(); await settled { Harness.backend.hidden }
   Harness.backend.applies=false; c.restore(); await settled({ Harness.backend.toggles == 3 }, timeout:.seconds(5)); await wait(2_200_000_000)
   check("ignored restore keeps recovery marker",Harness.backend.hidden && Harness.marker && Harness.backend.toggles == 3)
   Harness.backend.applies=true; c.restore(); await settled { !Harness.marker }
   check("later restore recovers",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 4)
  }
  func restartDuringRestore() async {
   Harness.prepare(); let c=DockVisibilityController(); c.hideForRecording(); await settled { Harness.backend.hidden }
   Harness.backend.delay=300_000_000; c.restore(); await wait(20_000_000); c.hideForRecording()
   await settled { Harness.backend.toggles == 3 && Harness.backend.hidden }
   check("restart during restore serializes visible then hidden",Harness.backend.hidden && Harness.marker && Harness.backend.toggles == 3)
   c.restore(); await settled { !Harness.marker }
   check("restarted capture still restores",!Harness.backend.hidden && Harness.backend.toggles == 4)
  }
  func noConfirmation() async {
   Harness.prepare(); Harness.backend.applies=false; let c=DockVisibilityController(); c.hideForRecording(); await wait(20_000_000)
   let clock=ContinuousClock(); let started=clock.now
   await c.restoreBeforeTermination(timeout:.milliseconds(100))
   check("unconfirmed shortcut has bounded quit",started.duration(to:clock.now) < .seconds(1) && Harness.marker && Harness.backend.toggles == 1)
   c.hideForRecording(); _=c.perform(NSSelectorFromString("applicationWillTerminate")); await wait()
   check("quit deadline never posts a second toggle",Harness.marker && Harness.backend.toggles == 1)
  }
  func unavailablePermission() async {
   Harness.prepare(); Harness.backend.available=false; let c=DockVisibilityController(); c.hideForRecording(); await wait()
   check("failed event posting retains recovery ownership",Harness.marker && Harness.backend.toggles == 0)
   Harness.backend.available=true; c.restore(); await settled { !Harness.marker }
   check("failed posting cannot hide Dock after stop",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 0)
  }
  func recoverPendingHide() async {
   Harness.prepare(delay:500_000_000); let c=DockVisibilityController(); c.hideForRecording(); await wait(20_000_000)
   await c.restoreBeforeTermination(timeout:.milliseconds(50)); _=c.perform(NSSelectorFromString("applicationWillTerminate")); await wait(50_000_000)
   check("quit deadline persists pending hide",Harness.marker && Harness.pending == true && !Harness.backend.hidden && Harness.backend.toggles == 1)
   let next=DockVisibilityController(); await wait(50_000_000)
   check("relaunch cannot clear marker before late hide",Harness.marker && Harness.pending == true && Harness.backend.toggles == 1)
   Harness.backend.delay=0; await settled { !Harness.marker }
   check("relaunch restores late hide exactly once",!Harness.backend.hidden && !Harness.marker && Harness.pending == nil && Harness.backend.toggles == 2)
   withExtendedLifetime(next) {}
  }
  func recoverPendingRestore() async {
   Harness.prepare(); let c=DockVisibilityController(); c.hideForRecording(); await settled { Harness.backend.hidden }
   Harness.backend.delay=500_000_000; c.restore(); await wait(20_000_000)
   await c.restoreBeforeTermination(timeout:.milliseconds(50)); _=c.perform(NSSelectorFromString("applicationWillTerminate")); await wait(50_000_000)
   check("quit deadline persists pending restore",Harness.marker && Harness.pending == false && Harness.backend.hidden && Harness.backend.toggles == 2)
   let next=DockVisibilityController(); await settled { !Harness.marker }
   check("relaunch observes pending restore without duplicate",!Harness.backend.hidden && !Harness.marker && Harness.pending == nil && Harness.backend.toggles == 2)
   withExtendedLifetime(next) {}
  }
  func captureDuringQuit() async {
   Harness.prepare(); let c=DockVisibilityController(); c.hideForRecording(); await settled { Harness.backend.hidden }
   Harness.backend.delay=300_000_000
   let quit=Task { @MainActor in await c.restoreBeforeTermination() }
   await wait(20_000_000); c.hideForRecording(); await quit.value
   check("late recording state cannot re-hide during quit",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 2)
  }
  func quitDelegate() async {
   Harness.prepare(); let c=DockVisibilityController(); c.hideForRecording(); await settled { Harness.backend.hidden }
   Harness.backend.delay=300_000_000
   let delegate=QuitDelegate(); delegate.dockVisibility=c; let app=TestApplication()
   check("quit delegate defers termination",delegate.applicationShouldTerminate(app) == .terminateLater)
   check("repeated quit remains deferred",delegate.applicationShouldTerminate(app) == .terminateLater)
   await settled { app.replies > 0 }; await wait()
   check("quit replies once after confirmed restoration",app.replies == 1 && !Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 2)
   let unconfigured=QuitDelegate()
   check("unconfigured delegate permits immediate quit",unconfigured.applicationShouldTerminate(app) == .terminateNow)
  }
  func processingLifecycle() async {
   Harness.prepare(); let engine=EngineHarness(); let binding=DockBindingHarness(engine:engine); await wait(10_000_000)
   for state:RecordingState in [.starting,.recording,.transcribing,.enhancing] {
    engine.recordingState=state; await wait(100_000_000)
    check("pipeline keeps Dock hidden during \\(state)",Harness.backend.hidden && Harness.marker && Harness.backend.toggles == 1)
   }
   engine.recordingState = .idle; await wait(100_000_000)
   check("pipeline completion restores Dock",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 2)
   withExtendedLifetime(binding) {}
  }
  func processingCancellation() async {
   for state:RecordingState in [.starting,.recording,.transcribing,.enhancing] {
    Harness.prepare(); let engine=EngineHarness(); let binding=DockBindingHarness(engine:engine); await wait(10_000_000)
    engine.recordingState = .starting; await wait(100_000_000)
    engine.recordingState=state; await wait(10_000_000)
    engine.recordingState = .idle; await wait(100_000_000)
    check("failure or cancellation from \\(state) restores Dock",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 2)
    withExtendedLifetime(binding) {}
   }
  }
  func processingAlreadyHidden() async {
   Harness.prepare(hidden:true); let engine=EngineHarness(); let binding=DockBindingHarness(engine:engine); await wait(10_000_000)
   for state:RecordingState in [.starting,.recording,.transcribing,.enhancing,.idle] { engine.recordingState=state; await wait(20_000_000) }
   check("pipeline preserves originally hidden Dock",Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 0)
   withExtendedLifetime(binding) {}
  }
  func settingOff() async {
   Harness.prepare(); let engine=EngineHarness(); let binding=DockBindingHarness(engine:engine); await wait(10_000_000)
   binding.hidesDockWhileRecording = false
   engine.recordingState = .recording; await wait(100_000_000)
   check("setting off never touches the Dock",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 0)
   engine.recordingState = .idle; await wait(100_000_000)
   withExtendedLifetime(binding) {}
  }
  func notchStyle() async {
   Harness.prepare(); let engine=EngineHarness(); let binding=DockBindingHarness(engine:engine); await wait(10_000_000)
   binding.recorderPanelStyle = .notch
   engine.recordingState = .recording; await wait(100_000_000)
   check("notch recorder never touches the Dock",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 0)
   engine.recordingState = .idle; await wait(100_000_000)
   withExtendedLifetime(binding) {}
  }
  func unrelatedBusyState() async {
   Harness.prepare(); let engine=EngineHarness(); let binding=DockBindingHarness(engine:engine); await wait(10_000_000)
   engine.recordingState = .busy; await wait(100_000_000)
   check("unrelated busy state leaves Dock unchanged",!Harness.backend.hidden && !Harness.marker && Harness.backend.toggles == 0)
   withExtendedLifetime(binding) {}
  }
  await quitDelegate()
  await initialVisible(); await alreadyHidden(); await repeatedStarts(); await stopInflight()
  await normalQuit(); await quitDuringRestore(); await quitDuringHide(); await recoverHiddenMarker()
  await lostFirstPost(); await ignoredHide(); await ignoredRestore(); await restartDuringRestore(); await noConfirmation()
  await unavailablePermission(); await captureDuringQuit(); await recoverPendingHide(); await recoverPendingRestore()
  await processingLifecycle(); await processingCancellation(); await processingAlreadyHidden(); await unrelatedBusyState()
  await settingOff(); await notchStyle()
  print("FAILURES",failures)
  if failures > 0 { exit(1) }
 }
}
'''
with tempfile.TemporaryDirectory(prefix="voce-dock-validation-") as directory:
    directory = Path(directory)
    swift_source = directory / "DockValidation.swift"
    executable = directory / "DockValidation"
    swift_source.write_text(pre + s + probe)
    subprocess.run([
        "xcrun", "swiftc", "-O", "-D", "VOCE_LOCAL", "-parse-as-library",
        str(swift_source), "-o", str(executable),
    ], check=True)
    sys.exit(subprocess.run([str(executable)]).returncode)
