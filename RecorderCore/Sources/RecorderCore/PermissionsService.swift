import AVFoundation
import Combine
import Foundation

/// Tracks the two permissions the app needs and points the user at the right
/// System Settings panel when one is missing (ТЗ F-4).
///
/// The microphone has a public API. System-audio capture does **not**: there is no
/// supported way to read or request `kTCCServiceAudioCapture`. AudioCap reaches for
/// a private TCC SPI; we deliberately do not ship private API, and instead infer the
/// state from whether a tap actually delivers audio — see ENGINEERING_NOTES §5.
@MainActor
public final class PermissionsService: ObservableObject {

    public enum Status: Equatable, Sendable {
        case granted
        case denied
        case undetermined
    }

    public enum Kind: Sendable, Equatable {
        case microphone
        case systemAudio

        /// Deep link into the matching System Settings pane.
        public var settingsURL: URL? {
            switch self {
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .systemAudio:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
            }
        }
    }

    @Published public private(set) var microphone: Status = .undetermined
    @Published public private(set) var systemAudio: Status = .undetermined

    /// System-audio state has no API to read, so what the last run observed is
    /// remembered. Without this the indicator reset to "не запитано" on every launch,
    /// telling a user who granted the permission weeks ago that it had never been
    /// asked for.
    private static let systemAudioKey = "systemAudioGranted"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let remembered = defaults.object(forKey: Self.systemAudioKey) as? Bool {
            systemAudio = remembered ? .granted : .denied
        }
        refresh()
    }

    /// Both permissions look usable — checked before starting a recording.
    public var isReadyToRecord: Bool {
        microphone != .denied && systemAudio != .denied
    }

    public func refresh() {
        microphone = Self.microphoneStatus()
    }

    /// Record what a capture attempt told us about system audio.
    ///
    /// The engine calls this after a run: callbacks that carry only digital silence
    /// mean the permission is missing, even though no API returned an error.
    public func noteSystemAudioResult(receivedAudio: Bool) {
        // A run that captured real audio proves the grant. A silent one only proves
        // silence — the room may simply have been quiet — so it never downgrades a
        // permission already known to work.
        guard receivedAudio || systemAudio != .granted else { return }
        systemAudio = receivedAudio ? .granted : .denied
        defaults.set(receivedAudio, forKey: Self.systemAudioKey)
    }

    public func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : .denied
    }

    private static func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }
}
