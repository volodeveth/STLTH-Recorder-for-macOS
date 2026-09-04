// Dev-bench helper: play a file into a SPECIFIC output device, bypassing the system
// default output.
//
// Why this exists: a process tap only delivers audio when the default output is a
// real device, so we cannot simply switch the default to BlackHole. Instead the
// default stays on the speakers (tap keeps working) and the test signal is pushed
// straight into BlackHole, which loops it back as the "microphone" input. A global
// tap captures the playing process regardless of which device it targets, so both
// tracks end up carrying the very same signal — exactly what a drift measurement needs.
//
// TEST INFRASTRUCTURE ONLY — the product never routes audio anywhere.
//
// Build: swiftc -O Tools/play-to-device/main.swift -o build/play-to-device \
//          -framework AVFoundation -framework CoreAudio
// Run:   ./build/play-to-device <file.wav> "BlackHole" [seconds]

import AVFoundation
import CoreAudio
import Foundation

func allDevices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ device: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString = "" as CFString
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
    }
    return status == noErr ? (value as String) : "?"
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("Використання: play-to-device <файл> <частина-назви-пристрою> [секунд]")
    exit(64)
}

let fileURL = URL(fileURLWithPath: arguments[1])
let needle = arguments[2]
let limitSeconds = arguments.count > 3 ? Double(arguments[3]) : nil

guard let target = allDevices().first(where: { deviceName($0).localizedCaseInsensitiveContains(needle) }) else {
    print("❌ пристрій «\(needle)» не знайдено")
    exit(1)
}
print("Пристрій виводу: \(deviceName(target)) (id \(target))")

let file = try AVAudioFile(forReading: fileURL)
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()

// Point the engine's output at the chosen device instead of the system default.
do {
    try engine.outputNode.auAudioUnit.setDeviceID(target)
} catch {
    print("❌ не вдалося призначити пристрій: \(error)")
    exit(1)
}

engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)

try engine.start()
player.scheduleFile(file, at: nil)
player.play()

let duration = limitSeconds ?? (Double(file.length) / file.fileFormat.sampleRate)
print("▶️  граю \(String(format: "%.0f", duration)) с у «\(deviceName(target))»")
Thread.sleep(forTimeInterval: duration)

player.stop()
engine.stop()
print("✅ готово")
