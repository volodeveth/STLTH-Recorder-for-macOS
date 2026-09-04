// Can a meeting be detected without touching the apps themselves?
//
// The obvious routes are bad: reading Chrome's tabs needs Apple Events permission
// and a scripting dialog, and matching process names breaks on every rename. But a
// meeting has one signature no conferencing app can avoid — **something is holding
// the microphone open**. CoreAudio publishes exactly that, per process, since
// macOS 14.4.
//
// This probe lists every process CoreAudio knows about and says which are capturing
// input right now, so the detector can be built on a fact rather than a heuristic.
//
// Build: swiftc -O Tools/meeting-probe/main.swift -o build/meeting-probe -framework CoreAudio

import CoreAudio
import Foundation
import Darwin

setbuf(stdout, nil)

let system = AudioObjectID(kAudioObjectSystemObject)

func processList() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
        return []
    }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func value<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, _ def: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else { return nil }
    var result = def
    let status = withUnsafeMutablePointer(to: &result) {
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
    }
    return status == noErr ? result : nil
}

func string(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    (value(objectID, selector, "" as CFString) as CFString?).map { $0 as String }
}

print("Спостерігаю за процесами, що тримають мікрофон. Ctrl+C — вихід.")
print("Запусти або заверши дзвінок і подивись, що зміниться.\n")

var previous = Set<String>()
while true {
    var capturing: [String] = []
    for process in processList() {
        let runningInput: UInt32? = value(process, kAudioProcessPropertyIsRunningInput, UInt32(0))
        guard runningInput == 1 else { continue }
        let bundle = string(process, kAudioProcessPropertyBundleID) ?? "?"
        let pid: pid_t? = value(process, kAudioProcessPropertyPID, pid_t(0))
        let name = pid.flatMap { id -> String? in
            let runningApp = NSWorkspace_localizedName(forPID: id)
            return runningApp
        } ?? bundle
        capturing.append("\(name) [\(bundle)]")
    }

    let current = Set(capturing)
    if current != previous {
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        print("[\(stamp.string(from: Date()))] мікрофон тримають: "
              + (capturing.isEmpty ? "ніхто" : capturing.joined(separator: ", ")))
        previous = current
    }
    Thread.sleep(forTimeInterval: 1)
}

/// `NSWorkspace` lives in AppKit; the probe stays CoreAudio-only and reads the name
/// from the process table instead.
func NSWorkspace_localizedName(forPID pid: pid_t) -> String? {
    var name = [CChar](repeating: 0, count: 1024)
    guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
    return String(cString: name)
}
