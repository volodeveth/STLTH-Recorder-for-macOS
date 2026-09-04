import CoreAudio
import Darwin
import Foundation
import OSLog

/// Notices that a meeting has started, so the user can be reminded to record it.
///
/// The ТЗ names the problem directly: «хтось просто забуває увімкнути запис, і
/// зустріч втрачається безповоротно». The decision to record stays with the user —
/// this only makes sure they are asked.
///
/// **How a meeting is recognised.** Not by reading browser tabs (that needs Apple
/// Events permission and a scripting prompt) and not by matching process names (which
/// break on every rename). A meeting has one signature no conferencing app can avoid:
/// something is holding the **microphone** open. CoreAudio publishes that per process
/// since macOS 14.4, and `Tools/meeting-probe` confirmed it reports `us.zoom.xos` the
/// moment a call begins.
public final class MeetingDetector {

    private let logger = Logger(subsystem: "ua.stlth.STLTHRecorder", category: "MeetingDetector")

    public struct Meeting: Equatable, Sendable {
        public let bundleID: String
        public let appName: String

        public init(bundleID: String, appName: String) {
            self.bundleID = bundleID
            self.appName = appName
        }
    }

    /// Apps whose microphone use means "a meeting", as opposed to dictation, voice
    /// memos or a game. Kept explicit: a reminder that fires while somebody dictates a
    /// note is worse than no reminder at all, because it teaches people to ignore it.
    public static let meetingBundleIDs: Set<String> = [
        "us.zoom.xos",                  // Zoom
        "com.google.Chrome",            // Google Meet, Zoom web client
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.tinyspeck.slackmacgap",    // Slack huddles
        "com.hnc.Discord",
    ]

    /// How long the microphone must stay held before this counts as a meeting.
    ///
    /// Conferencing apps grab the microphone briefly when you open their settings or
    /// preview your audio, and a reminder for that would be noise.
    static let confirmationDelay: TimeInterval = 5

    /// How long the microphone must stay free before the meeting counts as over.
    ///
    /// Muting in Zoom releases the device. Without this grace period every mute and
    /// unmute ended one "meeting" and began another — observed on a real call, which
    /// announced itself twice in thirty-two seconds.
    static let endGrace: TimeInterval = 60

    /// Has the meeting really ended, or is somebody simply on mute?
    static func hasEnded(freeSince: Date?, now: Date, grace: TimeInterval = endGrace) -> Bool {
        guard let freeSince else { return false }
        return now.timeIntervalSince(freeSince) >= grace
    }

    /// Pure decision, so the behaviour is testable without audio hardware.
    ///
    /// - Returns: the meeting to announce, or `nil` to stay quiet.
    static func decide(candidate: Meeting?,
                       heldSince: Date?,
                       alreadyAnnounced: Bool,
                       now: Date,
                       delay: TimeInterval = confirmationDelay) -> Meeting? {
        guard let candidate, let heldSince, !alreadyAnnounced else { return nil }
        guard now.timeIntervalSince(heldSince) >= delay else { return nil }
        return candidate
    }

    public var onMeetingStarted: ((Meeting) -> Void)?
    public var onMeetingEnded: (() -> Void)?

    private let queue = DispatchQueue(label: "ua.stlth.STLTHRecorder.meetings")
    private var timer: DispatchSourceTimer?
    private var heldSince: Date?
    private var current: Meeting?
    private var announced = false
    /// When the microphone was last seen free; `nil` while it is held.
    private var freeSince: Date?

    public init() {}

    deinit { stop() }

    public func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 2)
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
        logger.info("Meeting detection started")
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        heldSince = nil
        current = nil
        announced = false
    }

    /// Called after the user starts recording, so the reminder is not repeated for a
    /// meeting that is already being captured.
    public func suppressForCurrentMeeting() {
        queue.async { [weak self] in self?.announced = true }
    }

    private func poll() {
        let now = Date()
        let candidate = Self.currentMeetingApp()

        if candidate == nil {
            // Held → free: start counting, but do not call the meeting over yet.
            if freeSince == nil { freeSince = now }
            if Self.hasEnded(freeSince: freeSince, now: now) {
                if announced { onMeetingEnded?() }
                announced = false
                current = nil
                heldSince = nil
            }
        } else {
            freeSince = nil
            if candidate != current {
                // A different app took over — that is a new meeting.
                if candidate?.bundleID != current?.bundleID { announced = false }
                current = candidate
                heldSince = now
            }
        }

        if let meeting = Self.decide(candidate: current,
                                     heldSince: heldSince,
                                     alreadyAnnounced: announced,
                                     now: now) {
            announced = true
            logger.info("Meeting detected: \(meeting.appName, privacy: .public)")
            onMeetingStarted?(meeting)
        }
    }

    // MARK: - CoreAudio

    /// The first known conferencing app currently holding the microphone.
    static func currentMeetingApp() -> Meeting? {
        for process in processObjects() {
            let capturing: UInt32? = property(process, kAudioProcessPropertyIsRunningInput, UInt32(0))
            guard capturing == 1 else { continue }
            guard let bundleID = stringProperty(process, kAudioProcessPropertyBundleID),
                  meetingBundleIDs.contains(bundleID) else { continue }
            let pid: pid_t? = property(process, kAudioProcessPropertyPID, pid_t(0))
            return Meeting(bundleID: bundleID, appName: pid.flatMap(processName) ?? bundleID)
        }
        return nil
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func property<T>(_ objectID: AudioObjectID,
                                    _ selector: AudioObjectPropertySelector,
                                    _ defaultValue: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else { return nil }
        var value = defaultValue
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    private static func stringProperty(_ objectID: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        (property(objectID, selector, "" as CFString) as CFString?).map { $0 as String }
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
