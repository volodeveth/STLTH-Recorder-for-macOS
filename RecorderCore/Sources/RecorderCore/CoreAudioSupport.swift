import AVFoundation
import CoreAudio
import Foundation

/// Thin, typed helpers over the `AudioObjectGetPropertyData` C API.
///
/// Kept deliberately small — every selector used here appears in
/// `docs/notes/audiocap-findings.md` with the header it came from.
enum CoreAudioSupport {

    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func property<T>(_ objectID: AudioObjectID,
                            _ selector: AudioObjectPropertySelector,
                            _ defaultValue: T,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw AudioEngineError.coreAudio("AudioObjectGetPropertyDataSize(\(selector.fourCC))", status)
        }

        var value = defaultValue
        status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, $0)
        }
        guard status == noErr else {
            throw AudioEngineError.coreAudio("AudioObjectGetPropertyData(\(selector.fourCC))", status)
        }
        return value
    }

    static func string(_ objectID: AudioObjectID,
                       _ selector: AudioObjectPropertySelector) throws -> String {
        try property(objectID, selector, "" as CFString) as String
    }

    static func deviceUID(_ deviceID: AudioDeviceID) throws -> String {
        try string(deviceID, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ deviceID: AudioDeviceID) -> String {
        (try? string(deviceID, kAudioObjectPropertyName)) ?? "Невідомий пристрій"
    }

    /// The device applications actually play into (Zoom, Chrome, music).
    ///
    /// Not `kAudioHardwarePropertyDefaultSystemOutputDevice` — that one is for system
    /// alerts and can point somewhere else entirely. Building the aggregate around the
    /// wrong device yields zero IO callbacks, which is exactly what happened on the
    /// bench once a loopback device became the default output.
    static func defaultOutputDevice() throws -> AudioDeviceID {
        let id: AudioDeviceID = try property(systemObject, kAudioHardwarePropertyDefaultOutputDevice,
                                             AudioDeviceID(kAudioObjectUnknown))
        guard id != AudioObjectID(kAudioObjectUnknown) else {
            return try defaultSystemOutputDevice()
        }
        return id
    }

    static func defaultSystemOutputDevice() throws -> AudioDeviceID {
        try property(systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice,
                     AudioDeviceID(kAudioObjectUnknown))
    }

    /// `kAudioObjectUnknown` when the machine has no audio input at all —
    /// which is the case on the cloud test bench, and must not be fatal.
    static func defaultInputDevice() -> AudioDeviceID {
        let id = (try? property(systemObject, kAudioHardwarePropertyDefaultInputDevice,
                                AudioDeviceID(kAudioObjectUnknown))) ?? AudioDeviceID(kAudioObjectUnknown)
        return id
    }

    /// Our own process object, so a global tap can exclude us (spec §1).
    static func currentProcessObjectID() -> AudioObjectID {
        processObjectID(forPID: getpid())
    }

    /// CoreAudio's object for a given pid, or `kAudioObjectUnknown` if it has none.
    static func processObjectID(forPID processID: pid_t) -> AudioObjectID {
        var pid = processID
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = withUnsafeMutablePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(systemObject, &address,
                                       UInt32(MemoryLayout<pid_t>.size), pidPtr,
                                       &dataSize, &objectID)
        }
        return objectID
    }

    /// Channel counts of every input buffer a device delivers, in callback order.
    static func inputChannelLayout(_ deviceID: AudioDeviceID) -> [UInt32] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr else {
            return []
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map(\.mNumberChannels)
    }

    /// Convert a CoreAudio host time to seconds on a monotonic clock.
    static func seconds(fromHostTime hostTime: UInt64) -> Double {
        Double(AudioConvertHostTimeToNanos(hostTime)) / 1_000_000_000.0
    }
}

extension AudioObjectPropertySelector {
    var fourCC: String {
        let bytes = [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
                     UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

public enum AudioEngineError: LocalizedError, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case noSystemOutput
    case tapFormatUnavailable
    case unexpectedChannelLayout(expected: String, got: String)
    case alreadyRunning
    case setupTimedOut(String)

    public var description: String {
        switch self {
        case .coreAudio(let call, let status):
            return "CoreAudio: \(call) повернув помилку \(status)"
        case .noSystemOutput:
            return "Не знайдено пристрою системного виводу"
        case .tapFormatUnavailable:
            return "Не вдалося прочитати формат системного аудіопотоку"
        case .unexpectedChannelLayout(let expected, let got):
            return "Несподівана розкладка каналів: очікували \(expected), отримали \(got)"
        case .alreadyRunning:
            return "Запис уже триває"
        case .setupTimedOut(let call):
            return "CoreAudio: \(call) не відповів вчасно"
        }
    }

    /// `LocalizedError.errorDescription` is what `error.localizedDescription`
    /// actually reads. Declaring a plain `localizedDescription` property looked
    /// right and was never used: the menu showed "The operation couldn't be
    /// completed. (RecorderCore.AudioEngineError error 2.)" instead of the Ukrainian
    /// sentence written right here.
    public var errorDescription: String? { description }
}
