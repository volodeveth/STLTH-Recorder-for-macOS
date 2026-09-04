import Foundation
import Testing
@testable import RecorderCore

/// Fake engine so the state machine can be tested without any audio hardware.
final class MockAudioEngine: AudioEngineProtocol, @unchecked Sendable {
    var startCount = 0
    var stopCount = 0
    var startError: Error?
    let sessionDir: URL

    init(sessionDir: URL) {
        self.sessionDir = sessionDir
    }

    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stop() -> RecordingResult {
        stopCount += 1
        return RecordingResult(
            micURL: sessionDir.appendingPathComponent("mic.caf"),
            systemURL: sessionDir.appendingPathComponent("system.caf"),
            durationMs: 12345,
            inputDeviceName: "Mock Input",
            outputDeviceName: "Mock Output"
        )
    }
}

struct MockEngineError: Error {}

@MainActor
@Suite("RecorderController")
struct RecorderControllerTests {

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stlth-controller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeController(root: URL, configure: ((MockAudioEngine) -> Void)? = nil)
        -> (RecorderController, () -> MockAudioEngine?) {
        var created: MockAudioEngine?
        let store = SessionStore(root: root)
        let controller = RecorderController(store: store) { dir in
            let engine = MockAudioEngine(sessionDir: dir)
            configure?(engine)
            created = engine
            return engine
        }
        return (controller, { created })
    }

    @Test("Start moves idle -> recording and creates exactly one session")
    func startBeginsRecording() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (controller, engine) = makeController(root: root)
        #expect(controller.state == .idle)

        controller.startTapped(consentAt: Date())

        guard case .recording = controller.state else {
            Issue.record("очікували стан recording, отримали \(controller.state)")
            return
        }
        #expect(engine()?.startCount == 1)
        #expect(SessionStore(root: root).list().count == 1)
    }

    @Test("Tapping start twice does not create a duplicate session (ТЗ F-1)")
    func secondStartIsIgnored() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (controller, engine) = makeController(root: root)
        controller.startTapped(consentAt: Date())
        controller.startTapped(consentAt: Date())
        controller.startTapped(consentAt: Date())

        #expect(engine()?.startCount == 1)
        #expect(SessionStore(root: root).list().count == 1)
        guard case .recording = controller.state else {
            Issue.record("стан мав лишитись recording")
            return
        }
    }

    @Test("Stop moves back to idle and completes the session")
    func stopCompletesSession() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (controller, engine) = makeController(root: root)
        controller.startTapped(consentAt: Date())
        controller.stopTapped()

        #expect(controller.state == .idle)
        #expect(engine()?.stopCount == 1)

        let sessions = SessionStore(root: root).list()
        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .completed)
        #expect(sessions.first?.durationMs == 12345)
        #expect(sessions.first?.devices.input == "Mock Input")
    }

    @Test("Stop while idle is a no-op")
    func stopWhileIdleIsIgnored() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (controller, engine) = makeController(root: root)
        controller.stopTapped()

        #expect(controller.state == .idle)
        #expect(engine() == nil)
        #expect(SessionStore(root: root).list().isEmpty)
    }

    @Test("A failing engine leaves the app idle and the session marked interrupted")
    func engineFailureIsRecoverable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (controller, _) = makeController(root: root) { engine in
            engine.startError = MockEngineError()
        }
        controller.startTapped(consentAt: Date())

        #expect(controller.state == .idle)
        #expect(controller.lastError != nil)

        let sessions = SessionStore(root: root).list()
        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .interrupted)
    }

    @Test("Elapsed time is zero while idle and grows while recording")
    func elapsedTracksRecording() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (controller, _) = makeController(root: root)
        #expect(controller.elapsed == 0)

        controller.startTapped(consentAt: Date())
        Thread.sleep(forTimeInterval: 0.05)
        #expect(controller.elapsed > 0)

        controller.stopTapped()
        #expect(controller.elapsed == 0)
    }

    @Test("A previous error is cleared on a successful start")
    func errorClearedOnNewStart() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var shouldFail = true
        let store = SessionStore(root: root)
        let controller = RecorderController(store: store) { dir in
            let engine = MockAudioEngine(sessionDir: dir)
            if shouldFail { engine.startError = MockEngineError() }
            return engine
        }

        controller.startTapped(consentAt: Date())
        #expect(controller.lastError != nil)

        shouldFail = false
        controller.startTapped(consentAt: Date())
        #expect(controller.lastError == nil)
        guard case .recording = controller.state else {
            Issue.record("другий старт мав вдатися")
            return
        }
    }
}
