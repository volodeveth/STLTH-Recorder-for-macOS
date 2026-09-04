import Foundation
import Testing
@testable import RecorderCore

/// The rule that decides when to remind the user to start recording.
///
/// Getting this wrong is worse than having no reminder: one that fires while somebody
/// dictates a note, or fires twice for the same call, teaches people to ignore it.
@Suite("Meeting detection")
struct MeetingDetectorTests {

    private let zoom = MeetingDetector.Meeting(bundleID: "us.zoom.xos", appName: "zoom.us")
    private let now = Date()

    @Test("Nothing holding the microphone means no meeting")
    func silenceIsNotAMeeting() {
        #expect(MeetingDetector.decide(candidate: nil, heldSince: nil,
                                       alreadyAnnounced: false, now: now) == nil)
    }

    @Test("A brief grab of the microphone is not announced")
    func briefMicrophoneUseIsIgnored() {
        // Conferencing apps take the microphone for a moment when you open their audio
        // settings or preview the input.
        #expect(MeetingDetector.decide(candidate: zoom,
                                       heldSince: now.addingTimeInterval(-2),
                                       alreadyAnnounced: false, now: now) == nil)
    }

    @Test("Holding the microphone past the delay is a meeting")
    func sustainedMicrophoneUseIsAMeeting() {
        #expect(MeetingDetector.decide(candidate: zoom,
                                       heldSince: now.addingTimeInterval(-6),
                                       alreadyAnnounced: false, now: now) == zoom)
    }

    @Test("The same meeting is announced only once")
    func announcedOnlyOnce() {
        #expect(MeetingDetector.decide(candidate: zoom,
                                       heldSince: now.addingTimeInterval(-600),
                                       alreadyAnnounced: true, now: now) == nil)
    }

    @Test("Exactly at the threshold counts")
    func thresholdIsInclusive() {
        #expect(MeetingDetector.decide(candidate: zoom,
                                       heldSince: now.addingTimeInterval(-5),
                                       alreadyAnnounced: false, now: now) == zoom)
    }

    @Test("Conferencing apps are recognised, everyday microphone users are not")
    func onlyMeetingAppsCount() {
        #expect(MeetingDetector.meetingBundleIDs.contains("us.zoom.xos"))
        #expect(MeetingDetector.meetingBundleIDs.contains("com.google.Chrome"))
        // Dictation and voice memos must never trigger a reminder.
        #expect(!MeetingDetector.meetingBundleIDs.contains("com.apple.VoiceMemos"))
        #expect(!MeetingDetector.meetingBundleIDs.contains("com.apple.SpeechRecognitionCore"))
        // Neither may we detect ourselves and remind the user about our own capture.
        #expect(!MeetingDetector.meetingBundleIDs.contains("ua.stlth.STLTHRecorder"))
    }
}

extension MeetingDetectorTests {

    /// Muting in Zoom releases the microphone. A real call announced itself twice in
    /// thirty-two seconds because of it — on a live meeting that would mean a fresh
    /// reminder after every mute.
    @Test("Muting does not end the meeting")
    func muteDoesNotEndTheMeeting() {
        let now = Date()
        #expect(MeetingDetector.hasEnded(freeSince: now.addingTimeInterval(-5), now: now) == false)
        #expect(MeetingDetector.hasEnded(freeSince: now.addingTimeInterval(-30), now: now) == false)
    }

    @Test("A minute without the microphone ends the meeting")
    func sustainedSilenceEndsTheMeeting() {
        let now = Date()
        #expect(MeetingDetector.hasEnded(freeSince: now.addingTimeInterval(-61), now: now))
    }

    @Test("A microphone still held has not ended anything")
    func heldMicrophoneNeverEnds() {
        #expect(MeetingDetector.hasEnded(freeSince: nil, now: Date()) == false)
    }
}
