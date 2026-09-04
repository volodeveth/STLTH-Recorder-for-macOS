import AppKit
import RecorderCore
import SwiftUI
import UserNotifications

/// Watches for a meeting and asks the user whether to record it.
///
/// The ТЗ names the problem this solves: «хтось просто забуває увімкнути запис, і
/// зустріч втрачається безповоротно». The decision stays with the user — this only
/// makes sure the question is asked, once, at the moment it matters.
@MainActor
final class MeetingReminder: ObservableObject {

    /// Meeting in progress that the user has not started recording. The menu shows
    /// it even when a notification cannot be delivered.
    @Published private(set) var pending: MeetingDetector.Meeting?
    /// The meeting is over but the recording is not. Shown in the menu for the same
    /// reason: a banner can be missed, the menu bar cannot.
    @Published private(set) var recordingOutlivedMeeting = false

    @AppStorage("remindAboutMeetings") var isEnabled = true

    private let detector = MeetingDetector()
    private weak var controller: RecorderController?

    /// Detection starts here, in `init`, and deliberately not from a view.
    ///
    /// It first ran from `.task` on the menu's content — and `MenuBarExtra` builds
    /// that content lazily, on the first click. So detection did not begin until the
    /// user happened to open the menu, and the notification permission was never
    /// requested: a meeting on a fresh launch produced nothing at all. The one moment
    /// this feature exists for is exactly the one where nobody has opened the menu.
    init() {
        detector.onMeetingStarted = { [weak self] meeting in
            Task { @MainActor in self?.meetingStarted(meeting) }
        }
        detector.onMeetingEnded = { [weak self] in
            Task { @MainActor in self?.meetingEnded() }
        }
        detector.start()

        // Asked for at launch, not at the moment of the first meeting: a permission
        // dialog appearing mid-call is precisely the interruption this app avoids.
        // A denial is not fatal — the reminder still shows in the menu bar, so
        // neither the grant nor an error changes what happens next.
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func begin(controller: RecorderController) {
        self.controller = controller
    }

    private func meetingStarted(_ meeting: MeetingDetector.Meeting) {
        guard isEnabled else {
            return
        }
        // Already recording: the user did the right thing without being asked.
        guard controller?.isRecording == false else {
            detector.suppressForCurrentMeeting()
            return
        }
        pending = meeting
        notify(about: meeting)
    }

    /// The user started recording, so stop asking about this meeting.
    func acknowledge() {
        pending = nil
        recordingOutlivedMeeting = false
        detector.suppressForCurrentMeeting()
    }

    /// Recording stopped — nothing left to warn about.
    func recordingStopped() {
        recordingOutlivedMeeting = false
    }

    /// The call is over. If the recording is not, say so.
    ///
    /// Forgetting to stop is the worse of the two mistakes. Forgetting to start loses
    /// a meeting; forgetting to stop keeps capturing the room afterwards — the
    /// user's next call, a conversation with a colleague — audio nobody consented
    /// to, filed under a session that claims the other party agreed to it.
    private func meetingEnded() {
        pending = nil
        guard isEnabled, controller?.isRecording == true else { return }

        recordingOutlivedMeeting = true

        let content = UNMutableNotificationContent()
        content.title = "Зустріч завершено"
        content.body = "Запис досі триває. Зупинити його в STLTH Recorder for macOS?"
        content.sound = .default
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString,
                                       content: content, trigger: nil))
    }

    private func notify(about meeting: MeetingDetector.Meeting) {
        let content = UNMutableNotificationContent()
        content.title = "Почалася зустріч у \(meeting.appName)"
        content.body = "Увімкнути запис? Натисніть іконку STLTH Recorder for macOS у menu bar."
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
