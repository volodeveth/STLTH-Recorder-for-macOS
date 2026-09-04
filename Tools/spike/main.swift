// GATE-1 probe: does a *global* Core Audio process tap actually capture system
// audio on this rented cloud Mac?
//
// Deliberately standalone (no Xcode, no .app bundle) — CoreAudio tap API lives in
// CoreAudio.framework which ships with the Command Line Tools SDK.
//
// Build:
//   swiftc -O main.swift -o tapprobe -framework CoreAudio -framework AVFoundation \
//     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
// Run:
//   ./tapprobe [seconds]

import AVFoundation
import CoreAudio
import Foundation

// MARK: - Property helpers

func readProperty<T>(_ objectID: AudioObjectID,
                     _ selector: AudioObjectPropertySelector,
                     _ defaultValue: T,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: scope,
                                             mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    var err = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
    guard err == noErr else { throw Failure("GetPropertyDataSize(\(selector.fourCC)) failed: \(err)") }

    var value = defaultValue
    err = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, $0)
    }
    guard err == noErr else { throw Failure("GetPropertyData(\(selector.fourCC)) failed: \(err)") }
    return value
}

func readString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    try readProperty(objectID, selector, "" as CFString) as String
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension AudioObjectPropertySelector {
    var fourCC: String {
        let bytes = [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
                     UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

// MARK: - Probe

let durationSeconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 10.0) : 10.0
let system = AudioObjectID(kAudioObjectSystemObject)

print("=== GATE-1: global process tap probe ===")

// Our own process object ID, so the tap can exclude us (spec §1).
var ownProcessObjectID = AudioObjectID(kAudioObjectUnknown)
do {
    var pid = getpid()
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = withUnsafeMutablePointer(to: &pid) { pidPtr in
        AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), pidPtr,
                                   &dataSize, &ownProcessObjectID)
    }
    print("own pid \(getpid()) -> process object \(ownProcessObjectID) (err \(err))")
}

// 1. Create the global tap.
let excluded: [AudioObjectID] = ownProcessObjectID == AudioObjectID(kAudioObjectUnknown)
    ? [] : [ownProcessObjectID]
let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
tapDescription.uuid = UUID()
tapDescription.name = "STLTHRecorderProbeTap"
tapDescription.isPrivate = true
tapDescription.muteBehavior = CATapMuteBehavior.unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapErr = AudioHardwareCreateProcessTap(tapDescription, &tapID)
guard tapErr == noErr else {
    print("❌ AudioHardwareCreateProcessTap failed: \(tapErr)")
    exit(1)
}
print("✅ tap created: id=\(tapID), uuid=\(tapDescription.uuid.uuidString)")

// 2. Read the tap's stream format.
var tapASBD = AudioStreamBasicDescription()
do {
    tapASBD = try readProperty(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
    print("✅ tap format: \(tapASBD.mSampleRate) Hz, \(tapASBD.mChannelsPerFrame) ch, "
          + "flags=\(tapASBD.mFormatFlags), bits=\(tapASBD.mBitsPerChannel)")
} catch {
    print("❌ reading tap format failed: \(error)")
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

// 3. Build the aggregate device around the default system output + the tap.
var aggregateID = AudioObjectID(kAudioObjectUnknown)
do {
    let outputID: AudioDeviceID = try readProperty(system, kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                   AudioDeviceID(kAudioObjectUnknown))
    let outputUID = try readString(outputID, kAudioDevicePropertyDeviceUID)
    let outputName = (try? readString(outputID, kAudioObjectPropertyName)) ?? "?"
    print("default system output: \(outputName) [\(outputUID)]")

    // Is there any input device on this machine at all?
    let inputID: AudioDeviceID = (try? readProperty(system, kAudioHardwarePropertyDefaultInputDevice,
                                                    AudioDeviceID(kAudioObjectUnknown))) ?? AudioDeviceID(kAudioObjectUnknown)
    if inputID != AudioObjectID(kAudioObjectUnknown) {
        let inputName = (try? readString(inputID, kAudioObjectPropertyName)) ?? "?"
        print("default input: \(inputName)")
    } else {
        print("⚠️  no default input device on this machine (expected on this cloud Mac)")
    }

    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "STLTHRecorderProbeAggregate",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
        ]],
    ]

    let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
    guard err == noErr else {
        print("❌ AudioHardwareCreateAggregateDevice failed: \(err)")
        AudioHardwareDestroyProcessTap(tapID)
        exit(1)
    }
    print("✅ aggregate device created: id=\(aggregateID)")
}

// 4. Run the IO proc and measure what actually arrives.
final class Stats: @unchecked Sendable {
    var callbacks = 0
    var frames = 0
    var peak: Float = 0
    var sumSquares: Double = 0
    var samples = 0
    var bufferShape: String = "?"
    var firstHostTime: UInt64 = 0
    var lastHostTime: UInt64 = 0
    let lock = NSLock()
}
let stats = Stats()

guard let format = AVAudioFormat(streamDescription: &tapASBD) else {
    print("❌ AVAudioFormat from tap ASBD failed")
    exit(1)
}

let queue = DispatchQueue(label: "tapprobe.io", qos: .userInitiated)
var procID: AudioDeviceIOProcID?
let ioErr = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
    _, inInputData, inInputTime, _, _ in
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inInputData)).unsafeMutablePointer)

    stats.lock.lock()
    defer { stats.lock.unlock() }

    stats.callbacks += 1
    if stats.callbacks == 1 {
        stats.bufferShape = list.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: " + ")
        stats.firstHostTime = inInputTime.pointee.mHostTime
    }
    stats.lastHostTime = inInputTime.pointee.mHostTime

    for buffer in list {
        guard let data = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let ptr = data.bindMemory(to: Float.self, capacity: count)
        for i in 0..<count {
            let v = abs(ptr[i])
            if v > stats.peak { stats.peak = v }
            stats.sumSquares += Double(v) * Double(v)
        }
        stats.samples += count
        stats.frames += count / max(1, Int(buffer.mNumberChannels))
    }
}
guard ioErr == noErr, let procID else {
    print("❌ AudioDeviceCreateIOProcIDWithBlock failed: \(ioErr)")
    exit(1)
}

let startErr = AudioDeviceStart(aggregateID, procID)
guard startErr == noErr else {
    print("❌ AudioDeviceStart failed: \(startErr)")
    exit(1)
}
print("▶️  capturing for \(durationSeconds) s — play some audio now…")

Thread.sleep(forTimeInterval: durationSeconds)

AudioDeviceStop(aggregateID, procID)
AudioDeviceDestroyIOProcID(aggregateID, procID)
AudioHardwareDestroyAggregateDevice(aggregateID)
AudioHardwareDestroyProcessTap(tapID)

// 5. Verdict.
stats.lock.lock()
let rms = stats.samples > 0 ? sqrt(stats.sumSquares / Double(stats.samples)) : 0
print("""

--- results ---
IO callbacks:   \(stats.callbacks)
buffer shape:   \(stats.bufferShape)
frames:         \(stats.frames)  (~\(String(format: "%.2f", Double(stats.frames) / tapASBD.mSampleRate)) s)
peak amplitude: \(String(format: "%.6f", stats.peak))
RMS:            \(String(format: "%.6f", rms))
""")
stats.lock.unlock()

if stats.callbacks == 0 {
    print("❌ GATE-1 FAIL: no IO callbacks at all")
    exit(1)
} else if stats.peak == 0 {
    print("⚠️  GATE-1 PARTIAL: callbacks arrive but every sample is silence "
          + "(no TCC permission, or nothing was playing)")
    exit(2)
} else {
    print("✅ GATE-1 PASS: real system audio captured")
    exit(0)
}
