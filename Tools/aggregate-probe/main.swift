// Diagnostic: which aggregate-device layout actually delivers IO callbacks when a
// microphone sub-device is combined with a global process tap?
//
// The product's whole synchronisation argument rests on "mic + tap in ONE aggregate",
// so when that combination went silent on the bench it had to be pinned down rather
// than guessed at. This probe builds several variants and reports which ones run.
//
// Build: swiftc -O Tools/aggregate-probe/main.swift -o build/aggregate-probe \
//          -framework CoreAudio -framework AVFoundation

import AVFoundation
import CoreAudio
import Foundation

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

setbuf(stdout, nil) // unbuffered: results must appear even if a later variant hangs
let system = AudioObjectID(kAudioObjectSystemObject)
let outputID: AudioDeviceID = property(system, kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0))!
let inputID: AudioDeviceID = property(system, kAudioHardwarePropertyDefaultInputDevice, AudioDeviceID(0))!
let outputUID = str(outputID, kAudioDevicePropertyDeviceUID)!
let inputUID = str(inputID, kAudioDevicePropertyDeviceUID)!

print("output: \(str(outputID, kAudioObjectPropertyName) ?? "?") [\(outputUID)]")
print("input:  \(str(inputID, kAudioObjectPropertyName) ?? "?") [\(inputUID)]")
print("")

func makeTap() -> (AudioObjectID, UUID)? {
    var ownProcess = AudioObjectID(kAudioObjectUnknown)
    var pid = getpid()
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    _ = withUnsafeMutablePointer(to: &pid) {
        AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), $0, &size, &ownProcess)
    }

    let description = CATapDescription(stereoGlobalTapButExcludeProcesses:
        ownProcess == AudioObjectID(kAudioObjectUnknown) ? [] : [ownProcess])
    let uuid = UUID()
    description.uuid = uuid
    description.isPrivate = true
    description.muteBehavior = CATapMuteBehavior.unmuted

    var tapID = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }
    return (tapID, uuid)
}

/// Build an aggregate from `description`, run it for `seconds`, report callbacks.
func trial(_ label: String, seconds: Double = 2.0, build: (String) -> [String: Any]) {
    guard let (tapID, tapUUID) = makeTap() else {
        print("\(label): ❌ не вдалося створити tap")
        return
    }
    defer { AudioHardwareDestroyProcessTap(tapID) }

    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateAggregateDevice(build(tapUUID.uuidString) as CFDictionary, &aggregateID)
    guard status == noErr else {
        print("\(label): ❌ create aggregate → \(status)")
        return
    }
    defer { AudioHardwareDestroyAggregateDevice(aggregateID) }

    final class Counter: @unchecked Sendable {
        var callbacks = 0
        var shape = "-"
        var peak: Float = 0
    }
    let counter = Counter()

    var procID: AudioDeviceIOProcID?
    let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID,
                                                          DispatchQueue(label: "probe")) { _, input, _, _, _ in
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        counter.callbacks += 1
        if counter.callbacks == 1 {
            counter.shape = buffers.map { "\($0.mNumberChannels)ch" }.joined(separator: "+")
        }
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let ptr = data.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count where abs(ptr[i]) > counter.peak { counter.peak = abs(ptr[i]) }
        }
    }
    guard createStatus == noErr, let procID else {
        print("\(label): ❌ create IO proc → \(createStatus)")
        return
    }

    let startStatus = AudioDeviceStart(aggregateID, procID)
    guard startStatus == noErr else {
        print("\(label): ❌ AudioDeviceStart → \(startStatus)")
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        return
    }

    Thread.sleep(forTimeInterval: seconds)
    AudioDeviceStop(aggregateID, procID)
    AudioDeviceDestroyIOProcID(aggregateID, procID)

    let verdict = counter.callbacks > 0 ? "✅" : "❌"
    print("\(label): \(verdict) колбеків=\(counter.callbacks) буфери=\(counter.shape) peak=\(String(format: "%.4f", counter.peak))")
}

func tapList(_ uuid: String) -> [[String: Any]] {
    [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: uuid]]
}

func makeDescription(name: String,
                     main: String,
                     subDevices: [[String: Any]],
                     taps: [[String: Any]]) -> [String: Any] {
    var description = [String: Any]()
    description[kAudioAggregateDeviceNameKey] = name
    description[kAudioAggregateDeviceUIDKey] = UUID().uuidString
    description[kAudioAggregateDeviceMainSubDeviceKey] = main
    description[kAudioAggregateDeviceIsPrivateKey] = true
    description[kAudioAggregateDeviceIsStackedKey] = false
    description[kAudioAggregateDeviceTapAutoStartKey] = true
    description[kAudioAggregateDeviceSubDeviceListKey] = subDevices
    description[kAudioAggregateDeviceTapListKey] = taps
    return description
}

let inputSub: [String: Any] = [kAudioSubDeviceUIDKey: inputUID, kAudioSubDeviceDriftCompensationKey: true]
let inputSubPlain: [String: Any] = [kAudioSubDeviceUIDKey: inputUID]
let outputSub: [String: Any] = [kAudioSubDeviceUIDKey: outputUID]

print("--- варіанти ---")

trial("1. лише tap + output (як AudioCap)") { uuid in
    makeDescription(name: "probe1", main: outputUID, subDevices: [outputSub], taps: tapList(uuid))
}
trial("2. input + output, main=output") { uuid in
    makeDescription(name: "probe2", main: outputUID, subDevices: [inputSub, outputSub], taps: tapList(uuid))
}
trial("3. input + output, main=input") { uuid in
    makeDescription(name: "probe3", main: inputUID, subDevices: [inputSub, outputSub], taps: tapList(uuid))
}
trial("4. лише input + tap (без output)") { uuid in
    makeDescription(name: "probe4", main: inputUID, subDevices: [inputSubPlain], taps: tapList(uuid))
}
trial("5. input+output, main=output, без drift compensation") { uuid in
    makeDescription(name: "probe5", main: outputUID, subDevices: [inputSubPlain, outputSub],
                    taps: [[kAudioSubTapUIDKey: uuid]])
}
trial("6. output+input (зворотний порядок), main=output") { uuid in
    makeDescription(name: "probe6", main: outputUID, subDevices: [outputSub, inputSub], taps: tapList(uuid))
}
