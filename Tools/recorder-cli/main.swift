// Headless test bench for the capture core.
//
// Records a real session with AudioEngine + SessionStore and prints what landed on
// disk — the fastest way to validate GATE-2 without the menu bar UI.
//
// Build:  make recorder-cli
// Run:    ./build/recorder-cli record 30 [--dir /tmp/rec]

import AVFoundation
import Foundation

// Unbuffered: long runs must show progress even if the process is killed.
setbuf(stdout, nil)

func usage() -> Never {
    print("""
    Використання:
      recorder-cli record <секунд> [--dir <тека>] [--exclude-pid <pid>]
      recorder-cli recover <тека>

    Пише mic.caf, system.caf і meta.json у теку сесії та друкує підсумок.
    """)
    exit(64)
}

let arguments = CommandLine.arguments

// `recover <dir>` — reconcile sessions a crash left in "recording" state.
if arguments.count >= 3, arguments[1] == "recover" {
    let store = SessionStore(root: URL(fileURLWithPath: arguments[2]))
    store.recoverInterrupted()
    for meta in store.list() {
        print("\(meta.sessionId): \(meta.status.rawValue), \(meta.durationMs) мс")
    }
    exit(0)
}

guard arguments.count >= 3, arguments[1] == "record",
      let seconds = Double(arguments[2]), seconds > 0 else { usage() }

var root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("stlth-recorder-cli", isDirectory: true)
if let index = arguments.firstIndex(of: "--dir"), index + 1 < arguments.count {
    root = URL(fileURLWithPath: arguments[index + 1])
}
try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

let store = SessionStore(root: root)
let handle = try store.begin(consentAt: Date())
print("Сесія: \(handle.id)")
print("Тека:  \(handle.dir.path)")

// Bench-only: keep a helper process out of the tap. On this Mac the advisor has no
// microphone, so their voice is synthesised and pushed into the loopback by a
// separate process — which a global tap would otherwise capture as well, putting the
// same voice in both tracks.
var excludedPIDs: [pid_t] = []
var pidIndex = arguments.firstIndex(of: "--exclude-pid")
while let index = pidIndex, index + 1 < arguments.count {
    if let value = pid_t(arguments[index + 1]) { excludedPIDs.append(value) }
    pidIndex = arguments[(index + 1)...].firstIndex(of: "--exclude-pid")
}

let engine = AudioEngine(sessionDir: handle.dir, excludingFromTap: excludedPIDs)
if !excludedPIDs.isEmpty {
    print("Виключено з tap: \(excludedPIDs.map(String.init).joined(separator: ", "))")
}
do {
    try engine.start()
} catch {
    print("❌ Не вдалося почати запис: \(error)")
    try? store.interrupt(handle)
    exit(1)
}

print("▶️  Запис \(seconds) с… (грайте звук у Zoom / браузері)")
Thread.sleep(forTimeInterval: seconds)

let callbacks = engine.callbackCount
let micCallbacks = engine.micCallbackCount
let result = engine.stop()
try store.complete(handle, result: result)

print("""

--- підсумок ---
Тривалість: \(result.durationMs) мс
IO-колбеків: \(callbacks) (мікрофон: \(micCallbacks))
Режим:      \(result.captureMode.rawValue)
Вхід:       \(result.inputDeviceName)
Вихід:      \(result.outputDeviceName)
""")

// Verify the timeline invariant: samples == duration × 48000 in both tracks.
var allGood = true
for (name, url, expectedChannels) in [("mic.caf", result.micURL, 1),
                                      ("system.caf", result.systemURL, 2)] {
    guard let file = try? AVAudioFile(forReading: url) else {
        print("❌ \(name): не читається")
        allGood = false
        continue
    }
    let duration = Double(file.length) / file.fileFormat.sampleRate
    let expectedFrames = Int((Double(result.durationMs) / 1000.0 * 48000).rounded())
    let drift = abs(Int(file.length) - expectedFrames)
    let channelsOK = Int(file.fileFormat.channelCount) == expectedChannels
    // One IO buffer of slack (512 frames ≈ 10 ms) is normal at the tail.
    let lengthOK = drift <= 1024

    print("\(lengthOK && channelsOK ? "✅" : "⚠️ ") \(name): \(file.length) семплів "
          + "(\(String(format: "%.3f", duration)) с), \(file.fileFormat.channelCount) кан., "
          + "Δ до очікуваного = \(drift) семплів")
    if !lengthOK || !channelsOK { allGood = false }
}

let metaURL = handle.dir.appendingPathComponent("meta.json")
if let meta = try? SessionMeta.load(from: metaURL) {
    print("✅ meta.json валідний, статус: \(meta.status.rawValue)")
} else {
    print("❌ meta.json не читається")
    allGood = false
}

print(allGood ? "\n✅ ГОТОВО" : "\n⚠️  Є зауваження — див. вище")
exit(allGood ? 0 : 1)
