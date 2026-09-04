// Diagnostic: what exactly happens when a microphone sub-device joins a tap
// aggregate, and can the process recover from it *without* being killed?
//
// The bench found that adding the (virtual) input device to the aggregate does not
// merely produce silence — `AudioDeviceCreateIOProcIDWithBlock` blocks forever in a
// mach_msg to coreaudiod. That is a far worse failure than "no callbacks": it would
// freeze `AudioEngine.start()`, and with it the menu bar app.
//
// This probe answers the three questions the fallback design depends on:
//   A. is the known-good layout (tap + output) still healthy on this bench?
//   B. does a plain IO proc straight on the input device work? (the fallback's mic leg)
//   C. after the hang, can the SAME process still build a working tap-only aggregate,
//      or is the HAL client wedged until the process dies?
//
// Build: swiftc -O Tools/deadlock-probe/main.swift -o build/deadlock-probe \
//          -framework CoreAudio -framework AVFoundation

import AVFoundation
import CoreAudio
import Foundation

setbuf(stdout, nil) // results must survive a hang in a later step

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

print("output: \(str(outputID, kAudioObjectPropertyName) ?? "?") [\(outputUID)]")
print("input:  \(str(inputID, kAudioObjectPropertyName) ?? "?") [\(inputUID)]")
print("")

/// Run `work` on its own thread and give up on it after `seconds`.
///
/// A blocked CoreAudio call cannot be cancelled — the thread stays parked in mach_msg
/// forever. That is precisely what makes this measurement worth taking: it tells us
/// whether abandoning the thread is survivable.
@discardableResult
func withDeadline(_ seconds: TimeInterval, _ work: @escaping () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        work()
        done.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()
    return done.wait(timeout: .now() + seconds) == .success
}

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

func makeDescription(name: String, main: String,
                     subDevices: [[String: Any]], taps: [[String: Any]]) -> [String: Any] {
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

final class Counter: @unchecked Sendable {
    var callbacks = 0
    var shape = "-"
    var peak: Float = 0

    func absorb(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        callbacks += 1
        if callbacks == 1 { shape = buffers.map { "\($0.mNumberChannels)ch" }.joined(separator: "+") }
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let pointer = data.bindMemory(to: Float.self, capacity: count)
            for index in 0..<count where abs(pointer[index]) > peak { peak = abs(pointer[index]) }
        }
    }

    var verdict: String {
        "\(callbacks > 0 ? "✅" : "❌") колбеків=\(callbacks) буфери=\(shape) peak=\(String(format: "%.4f", peak))"
    }
}

/// Create an IO proc on `deviceID`, run it for `seconds`, report what arrived.
func runDevice(_ deviceID: AudioObjectID, label: String, seconds: Double = 2.0) {
    let counter = Counter()
    var procID: AudioDeviceIOProcID?
    let queue = DispatchQueue(label: "probe.\(label)")

    let created = withDeadline(5) {
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
            counter.absorb(input)
        }
        if status != noErr { print("   create IO proc → \(status)") }
    }
    guard created else {
        print("\(label): ⛔️ ЗАВИС у AudioDeviceCreateIOProcIDWithBlock (5 с без відповіді)")
        return
    }
    guard let procID else {
        print("\(label): ❌ IO proc не створено")
        return
    }

    let started = withDeadline(5) {
        let status = AudioDeviceStart(deviceID, procID)
        if status != noErr { print("   AudioDeviceStart → \(status)") }
    }
    guard started else {
        print("\(label): ⛔️ ЗАВИС у AudioDeviceStart")
        return
    }

    Thread.sleep(forTimeInterval: seconds)
    withDeadline(5) {
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
    }
    print("\(label): \(counter.verdict)")
}

/// Build an aggregate from `subDevices` + a fresh tap and run it.
/// Returns the aggregate id so the caller can decide whether destroying it is safe.
@discardableResult
func runAggregate(_ label: String, main: String, subDevices: [[String: Any]],
                  seconds: Double = 2.0, destroy: Bool = true) -> AudioObjectID {
    guard let (tapID, tapUUID) = makeTap() else {
        print("\(label): ❌ не вдалося створити tap")
        return AudioObjectID(kAudioObjectUnknown)
    }

    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    let description = makeDescription(name: label, main: main, subDevices: subDevices,
                                      taps: [[kAudioSubTapDriftCompensationKey: true,
                                              kAudioSubTapUIDKey: tapUUID.uuidString]])
    let createdAggregate = withDeadline(5) {
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        if status != noErr { print("   create aggregate → \(status)") }
    }
    guard createdAggregate, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
        print("\(label): ⛔️ ЗАВИС/помилка у AudioHardwareCreateAggregateDevice")
        return AudioObjectID(kAudioObjectUnknown)
    }

    runDevice(aggregateID, label: label, seconds: seconds)

    if destroy {
        let destroyed = withDeadline(5) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
        }
        if !destroyed { print("   ⛔️ знищення aggregate/tap теж зависло") }
    }
    return aggregateID
}

let inputSub: [String: Any] = [kAudioSubDeviceUIDKey: inputUID,
                               kAudioSubDeviceDriftCompensationKey: true]
let outputSub: [String: Any] = [kAudioSubDeviceUIDKey: outputUID]

print("=== A. здоров'я стенда: tap + output (відома робоча конфігурація) ===")
runAggregate("A", main: outputUID, subDevices: [outputSub])

print("\n=== B. нога fallback: IO proc прямо на вхідному пристрої, без aggregate ===")
runDevice(inputID, label: "B")

print("\n=== C. підозрюваний: input + output + tap в одному aggregate ===")
runAggregate("C", main: outputUID, subDevices: [inputSub, outputSub])

print("\n=== D. чи вижив процес: знову tap + output ПІСЛЯ зависання ===")
runAggregate("D", main: outputUID, subDevices: [outputSub])

print("\n=== E. і мікрофонна нога після зависання ===")
runDevice(inputID, label: "E")

print("\nГотово.")
exit(0)
