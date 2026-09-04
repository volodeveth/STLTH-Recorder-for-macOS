import CoreAudio
import Foundation
import OSLog

/// Notices when the user switches the default input or output device mid-meeting
/// (plugging in AirPods is the everyday case).
///
/// The engine reacts by rebuilding its aggregate device; the gap that creates is
/// padded with silence, so the timeline never shifts (spec §4).
public final class DeviceMonitor {

    private let logger = Logger(subsystem: "ua.stlth.STLTHRecorder", category: "DeviceMonitor")

    /// Called on `DeviceMonitor`'s own queue with the new device name — **not** on the
    /// main queue. Anything touching the UI has to hop to the main actor itself.
    public var onDefaultInputChanged: ((String) -> Void)?
    public var onDefaultOutputChanged: ((String) -> Void)?

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// A private queue rather than `DispatchQueue.main`.
    ///
    /// CoreAudio delivers these blocks through the queue it was handed, so a main-queue
    /// listener only fires while the main run loop is actually turning. A headless
    /// recorder whose main thread sits in `Thread.sleep` would therefore never learn
    /// that the user switched devices — which is exactly how this went unnoticed until
    /// the bench test reported zero device changes on a run that had two.
    private let queue = DispatchQueue(label: "ua.stlth.STLTHRecorder.devices")

    public init() {}

    deinit { stop() }

    public static var currentInputName: String {
        let id = CoreAudioSupport.defaultInputDevice()
        guard id != AudioObjectID(kAudioObjectUnknown) else { return "Немає мікрофона" }
        return CoreAudioSupport.deviceName(id)
    }

    public static var currentOutputName: String {
        guard let id = try? CoreAudioSupport.defaultOutputDevice(),
              id != AudioObjectID(kAudioObjectUnknown) else { return "Невідомий пристрій" }
        return CoreAudioSupport.deviceName(id)
    }

    public var currentInputName: String { Self.currentInputName }
    public var currentOutputName: String { Self.currentOutputName }

    public func start() {
        guard listeners.isEmpty else { return }
        observe(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            guard let self else { return }
            let name = self.currentInputName
            self.logger.info("Default input changed: \(name, privacy: .public)")
            self.onDefaultInputChanged?(name)
        }
        // DefaultOutputDevice, not DefaultSystemOutputDevice: the latter is where
        // alerts and beeps go, the former is where Zoom and Chrome actually play —
        // and the aggregate is built around the former. On this bench the two are
        // different devices, which is the only reason the mismatch was visible.
        observe(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            guard let self else { return }
            let name = self.currentOutputName
            self.logger.info("Default output changed: \(name, privacy: .public)")
            self.onDefaultOutputChanged?(name)
        }
    }

    public func stop() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(CoreAudioSupport.systemObject, &address, queue, block)
        }
        listeners.removeAll()
    }

    private func observe(_ selector: AudioObjectPropertySelector, handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(CoreAudioSupport.systemObject,
                                                        &address, queue, block)
        guard status == noErr else {
            logger.error("Failed to observe \(selector.fourCC, privacy: .public): \(status)")
            return
        }
        listeners.append((address, block))
    }
}
