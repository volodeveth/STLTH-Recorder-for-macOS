import RecorderCore
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct STLTHRecorderApp: App {
    @StateObject private var controller = AppEnvironment.makeController()
    @StateObject private var permissions = PermissionsService()
    @StateObject private var reminder = MeetingReminder()
    @StateObject private var mixdown = MixdownService(store: SessionStore())
    @StateObject private var models = ModelInstaller()
    @StateObject private var transcription = TranscriptionService(store: SessionStore())

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller,
                        permissions: permissions,
                        reminder: reminder,
                        mixdown: mixdown,
                        models: models,
                        transcription: transcription)

        } label: {
            // The label is built at launch, unlike the menu's content — so this is
            // where the reminder learns about the controller.
            Color.clear.frame(width: 0, height: 0)
                .onAppear {
                    reminder.begin(controller: controller)
                    // Sessions a crash left behind have just had their CAF headers
                    // repaired; only now is it safe to fold them into a mixdown.
                    mixdown.mixRecovered(controller.recoveredSessions)
                }
            // Status has to be impossible to miss (ТЗ F-4): the icon fills in and the
            // elapsed time sits right in the menu bar while recording.
            if controller.isRecording {
                HStack(spacing: 4) {
                    // Explicitly red, not `.multicolor`: the symbol's own palette
                    // renders amber in the menu bar, which reads as a warning rather
                    // than "recording" — and sits right next to the orange dot macOS
                    // shows whenever the microphone is live, so the two blended into
                    // each other.
                    Image(systemName: "record.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.red)
                    Text(TimeFormatting.elapsed(controller.elapsed))
                        .monospacedDigit()
                }
            } else {
                Image(systemName: "record.circle")
            }
        }

        Window("Підтвердження згоди", id: "consent") {
            ConsentWindow(controller: controller, permissions: permissions, reminder: reminder)
        }
        .windowResizability(.contentSize)

        Window("Транскрибація", id: TranscriptionSetupWindow.id) {
            TranscriptionSetupWindow(models: models)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(models: models)
        }
    }
}

/// Wraps the consent sheet so it can close its own window.
///
/// `dismissWindow` lives in the environment, which a `Scene` body cannot read —
/// it has to be taken inside a `View`.
struct ConsentWindow: View {
    @ObservedObject var controller: RecorderController
    @ObservedObject var permissions: PermissionsService
    @ObservedObject var reminder: MeetingReminder
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ConsentSheet(
            diskLevel: DiskGuard.level(at: SessionStore.defaultRoot),
            onConfirm: { consentAt in
                dismissWindow(id: "consent")
                // The microphone prompt must be answered *before* the engine touches
                // CoreAudio. While that TCC decision is pending,
                // `AudioDeviceCreateIOProcIDWithBlock` does not return at all — and
                // `startTapped` runs on the main actor, so the menu bar would freeze
                // behind an invisible dialog (reproduced on the bench).
                Task { @MainActor in
                    // The system-audio prompt is raised from inside the engine, so the
                    // app has to be frontmost before that call, not after it.
                    bringAppToFront()
                    permissions.refresh()
                    if permissions.microphone == .undetermined {
                        await permissions.requestMicrophone()
                    }
                    controller.startTapped(consentAt: consentAt)
                    // Recording has begun: stop asking about this meeting.
                    if controller.isRecording { reminder.acknowledge() }
                }
            },
            onCancel: { dismissWindow(id: "consent") }
        )
    }
}

/// Turn on launch-at-login the first time the app ever runs.
///
/// The ТЗ describes the product as a "menu bar agent: без вікна в Dock, автозапуск
/// при вході в систему (перемикається в налаштуваннях)" — the toggle exists to turn
/// it *off*. Shipping it off by default also breaks acceptance criterion #5, which
/// requires recording to work after a reboot: an app that never started cannot
/// record anything.
///
/// Done exactly once, keyed in defaults, so switching it off in Settings is not
/// undone at the next launch.
@MainActor
private func enableLaunchAtLoginOnFirstRun() {
    let key = "didConfigureLaunchAtLogin"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    do {
        try SMAppService.mainApp.register()
    } catch {
        // Not fatal: the user can still switch it on in Settings.
        NSLog("Не вдалося увімкнути автозапуск при першому запуску: \(error.localizedDescription)")
    }
}

enum AppEnvironment {
    @MainActor
    static func makeController() -> RecorderController {
        let controller = RecorderController(store: SessionStore()) { sessionDir in
            AudioEngine(sessionDir: sessionDir)
        }
        // A session left as "recording" by a crash is reconciled at launch (spec §4).
        controller.recoverInterruptedSessions()
        enableLaunchAtLoginOnFirstRun()
        return controller
    }
}
