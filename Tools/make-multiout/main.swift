// Dev-bench helper: create a Multi-Output device (speakers + BlackHole) and make it
// the default output, so one signal reaches both the process tap and the loopback
// "microphone" at the same time.
//
// This is TEST INFRASTRUCTURE ONLY. The product never creates or requires virtual
// audio devices — that is a hard constraint of the ТЗ (F-2).
//
// Build: swiftc -O Tools/make-multiout/main.swift -o build/make-multiout -framework CoreAudio
// Run:   ./build/make-multiout create | remove

import CoreAudio
import Foundation

let kMultiOutUID = "ua.stlth.devbench.multiout"
let kMultiOutName = "STLTH Dev Multi-Output"

func property<T>(_ objectID: AudioObjectID,
                 _ selector: AudioObjectPropertySelector,
                 _ defaultValue: T,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else { return nil }
    var value = defaultValue
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
    }
    return status == noErr ? value : nil
}

func allDevices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
    else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
}

func uid(_ device: AudioDeviceID) -> String? {
    (property(device, kAudioDevicePropertyDeviceUID, "" as CFString) as CFString?).map { $0 as String }
}

func name(_ device: AudioDeviceID) -> String {
    ((property(device, kAudioObjectPropertyName, "" as CFString) as CFString?).map { $0 as String }) ?? "?"
}

func findDevice(named needle: String) -> AudioDeviceID? {
    allDevices().first { name($0).localizedCaseInsensitiveContains(needle) }
}

func setDefaultOutput(_ device: AudioDeviceID) -> Bool {
    var value = device
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "create"

if command == "remove" {
    if let existing = allDevices().first(where: { uid($0) == kMultiOutUID }) {
        if let speakers = findDevice(named: "Speakers") { _ = setDefaultOutput(speakers) }
        let status = AudioHardwareDestroyAggregateDevice(existing)
        print(status == noErr ? "✅ Multi-Output видалено" : "❌ помилка \(status)")
    } else {
        print("Multi-Output не знайдено")
    }
    exit(0)
}

guard let speakers = findDevice(named: "Speakers"), let speakersUID = uid(speakers) else {
    print("❌ не знайдено вбудовані динаміки")
    exit(1)
}
guard let blackhole = findDevice(named: "BlackHole"), let blackholeUID = uid(blackhole) else {
    print("❌ не знайдено BlackHole — встановіть: brew install --cask blackhole-2ch")
    exit(1)
}

print("динаміки: \(name(speakers)) [\(speakersUID)]")
print("loopback: \(name(blackhole)) [\(blackholeUID)]")

if let existing = allDevices().first(where: { uid($0) == kMultiOutUID }) {
    _ = AudioHardwareDestroyAggregateDevice(existing)
}

// A "Multi-Output Device" is an aggregate with the stacked flag set: the same audio
// is mirrored to every sub-device instead of channels being concatenated.
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: kMultiOutName,
    kAudioAggregateDeviceUIDKey: kMultiOutUID,
    kAudioAggregateDeviceMainSubDeviceKey: speakersUID,
    kAudioAggregateDeviceIsPrivateKey: false,
    kAudioAggregateDeviceIsStackedKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: speakersUID],
        [kAudioSubDeviceUIDKey: blackholeUID, kAudioSubDeviceDriftCompensationKey: true],
    ],
]

var multiOut = AudioObjectID(kAudioObjectUnknown)
let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &multiOut)
guard status == noErr else {
    print("❌ AudioHardwareCreateAggregateDevice: \(status)")
    exit(1)
}
print("✅ створено Multi-Output id=\(multiOut)")

Thread.sleep(forTimeInterval: 1.0) // let CoreAudio publish the device
print(setDefaultOutput(multiOut) ? "✅ призначено виходом за замовчуванням"
                                 : "❌ не вдалося призначити виходом")
