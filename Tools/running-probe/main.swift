// Diagnostic for the watchdog design: does our aggregate device report itself as
// running while nothing is playing?
//
// The plan originally called for "no IO callback for 3 s → rebuild the engine". The
// bench killed that idea: a process tap only delivers callbacks while some process
// is actually playing, so silence — an ordinary pause in a meeting — would trigger a
// rebuild every time. A watchdog needs a signal that means "the graph is broken",
// not "the room is quiet".
//
// `kAudioDevicePropertyDeviceIsRunning` is the candidate. This probe starts the real
// capture layout and samples that property through a stretch of silence and a stretch
// of audio. If it stays true through silence and only drops on a genuine failure, it
// is a sound watchdog signal; if it tracks whether audio flows, it is the same broken
// idea wearing a different hat.
//
// Build: swiftc -O Tools/running-probe/main.swift -o build/running-probe \
//          -framework CoreAudio -framework AVFoundation

import AVFoundation
import CoreAudio
import Foundation

setbuf(stdout, nil)

func property<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, _ def: T,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else { return nil }
    var value = def
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
    }
    return status == noErr ? value : nil
}

func str(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    (property(objectID, selector, "" as CFString) as CFString?).map { $0 as String }
}

let system = AudioObjectID(kAudioObjectSystemObject)
let outputID: AudioDeviceID = property(system, kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0))!
let inputID: AudioDeviceID = property(system, kAudioHardwarePropertyDefaultInputDevice, AudioDeviceID(0))!
let outputUID = str(outputID, kAudioDevicePropertyDeviceUID)!
let inputUID = str(inputID, kAudioDevicePropertyDeviceUID)!

print("вихід: \(str(outputID, kAudioObjectPropertyName) ?? "?")")
print("вхід:  \(str(inputID, kAudioObjectPropertyName) ?? "?")")
print("")

// The product's real layout: microphone + tap in one aggregate.
var ownProcess = AudioObjectID(kAudioObjectUnknown)
var pid = getpid()
var translate = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
var translateSize = UInt32(MemoryLayout<AudioObjectID>.size)
_ = withUnsafeMutablePointer(to: &pid) {
    AudioObjectGetPropertyData(system, &translate, UInt32(MemoryLayout<pid_t>.size), $0,
                               &translateSize, &ownProcess)
}

let description = CATapDescription(stereoGlobalTapButExcludeProcesses:
    ownProcess == AudioObjectID(kAudioObjectUnknown) ? [] : [ownProcess])
let tapUUID = UUID()
description.uuid = tapUUID
description.isPrivate = true
description.muteBehavior = CATapMuteBehavior.unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
    print("❌ не вдалося створити tap")
    exit(1)
}

var aggregate: [String: Any] = [:]
aggregate[kAudioAggregateDeviceNameKey] = "STLTHRunningProbe"
aggregate[kAudioAggregateDeviceUIDKey] = UUID().uuidString
aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
aggregate[kAudioAggregateDeviceIsPrivateKey] = true
aggregate[kAudioAggregateDeviceIsStackedKey] = false
aggregate[kAudioAggregateDeviceTapAutoStartKey] = true
aggregate[kAudioAggregateDeviceSubDeviceListKey] = [
    [kAudioSubDeviceUIDKey: inputUID, kAudioSubDeviceDriftCompensationKey: true],
    [kAudioSubDeviceUIDKey: outputUID],
]
aggregate[kAudioAggregateDeviceTapListKey] = [
    [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID.uuidString],
]

var aggregateID = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
    print("❌ не вдалося створити aggregate")
    exit(1)
}

final class Counter: @unchecked Sendable { var callbacks = 0 }
let counter = Counter()

var procID: AudioDeviceIOProcID?
guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID,
                                         DispatchQueue(label: "probe")) { _, _, _, _, _ in
    counter.callbacks += 1
} == noErr, let procID else {
    print("❌ не вдалося створити IO proc")
    exit(1)
}
guard AudioDeviceStart(aggregateID, procID) == noErr else {
    print("❌ AudioDeviceStart не вдався")
    exit(1)
}

func isRunning() -> String {
    guard let value: UInt32 = property(aggregateID, kAudioDevicePropertyDeviceIsRunning, UInt32(0)) else {
        return "н/д"
    }
    return value != 0 ? "true" : "false"
}

func sample(_ label: String, seconds: Int) {
    print("--- \(label) ---")
    for tick in 1...seconds {
        let before = counter.callbacks
        Thread.sleep(forTimeInterval: 1)
        let delta = counter.callbacks - before
        print("  \(tick) с: DeviceIsRunning=\(isRunning())  колбеків за секунду=\(delta)")
    }
    print("")
}

sample("тиша (нічого не грає)", seconds: 5)

print("вмикаю звук…")
let player = Process()
player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
player.arguments = [CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/clicks30.wav"]
try? player.run()
Thread.sleep(forTimeInterval: 1)

sample("звук грає", seconds: 5)

player.terminate()
Thread.sleep(forTimeInterval: 1)
// Long tail on purpose: the question is not whether the tap keeps ticking for a
// second after the audio stops, but whether it eventually goes idle — which decides
// what "no callbacks" is allowed to mean.
sample("знову тиша (довгий хвіст)", seconds: 40)

AudioDeviceStop(aggregateID, procID)
AudioDeviceDestroyIOProcID(aggregateID, procID)
AudioHardwareDestroyAggregateDevice(aggregateID)
AudioHardwareDestroyProcessTap(tapID)
print("Готово.")
