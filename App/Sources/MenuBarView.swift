import AppKit
import RecorderCore
import SwiftUI

/// Bring the app to the front before anything that opens a window or a system
/// dialog.
///
/// A menu bar agent (`LSUIElement`) is never the active application, and macOS puts
/// the dialogs it triggers *behind* whatever is frontmost. On the bench the
/// microphone prompt appeared behind a Chrome window: from the user's side the
/// button simply did nothing, and nothing on screen suggested that windows had to be
/// moved to find it.
@MainActor
func bringAppToFront() {
    NSApplication.shared.activate(ignoringOtherApps: true)
}

/// The whole app lives in this menu (ТЗ F-4): start/stop, current status,
/// recent sessions, permissions and settings.
struct MenuBarView: View {
    @ObservedObject var controller: RecorderController
    @ObservedObject var permissions: PermissionsService
    @ObservedObject var reminder: MeetingReminder
    @ObservedObject var mixdown: MixdownService
    @ObservedObject var models: ModelInstaller
    @ObservedObject var transcription: TranscriptionService
    /// A `Window` scene opens only through this — assigning to a `@State` flag
    /// compiles cleanly and does nothing at all, which is how "Почати запис"
    /// silently stopped working.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if controller.isRecording {
                if reminder.recordingOutlivedMeeting {
                    // The call is over and this is still running — the case where a
                    // recorder quietly captures what nobody agreed to.
                    Text("● Зустріч завершено — запис триває")
                    Divider()
                }
                Button("Зупинити запис (\(TimeFormatting.elapsed(controller.elapsed)))") {
                    controller.stopTapped()
                    // There is no API to read the system-audio permission, so the
                    // finished session is the evidence: buffers full of digital
                    // silence mean it was never granted. Without this the indicator
                    // stayed "буде запитано при першому записі" forever, however many
                    // recordings had already succeeded.
                    if let result = controller.lastResult {
                        permissions.noteSystemAudioResult(receivedAudio: result.systemAudioDetected)
                    }
                    reminder.recordingStopped()
                    // Derived, and deliberately after the fact: the mixdown is built
                    // in the background so a slow encode can never delay the end of a
                    // recording or make a finished session look unfinished.
                    mixdown.mixAfterRecording(controller.lastCompletedMeta)
                    // Same rule as the mixdown: derived, in the background, one
                    // session at a time — a recording that ends while another is
                    // still being recognised simply joins the queue.
                    transcription.transcribeAfterRecording(controller.lastCompletedMeta)
                }
            } else {
                if let meeting = reminder.pending {
                    // The user is in a call and not recording it — the one moment
                    // this app exists to catch.
                    Text("● Зустріч у \(meeting.appName) — запис не ведеться")
                    Divider()
                }
                Button(reminder.pending == nil ? "Почати запис" : "Почати запис зустрічі") {
                    bringAppToFront()
                    openWindow(id: "consent")
                }
                    .disabled(controller.state != .idle)
            }

            Divider()

            RecentSessionsMenu(controller: controller, models: models, mixdown: mixdown,
                               transcription: transcription)

            Divider()

            PermissionsSection(permissions: permissions)

            if let error = controller.lastError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            SettingsLink { Text("Налаштування…") }
            Button("Перевірити оновлення…") { Updates.openReleasesPage() }

            Divider()

            Button("Вийти") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// Permission indicators — always visible, with a way back when one is revoked.
struct PermissionsSection: View {
    @ObservedObject var permissions: PermissionsService

    var body: some View {
        Text("Дозволи")
            .font(.caption)

        PermissionRow(title: "Мікрофон",
                      status: permissions.microphone,
                      kind: .microphone) {
            Task { await permissions.requestMicrophone() }
        }
        PermissionRow(title: "Системне аудіо",
                      status: permissions.systemAudio,
                      kind: .systemAudio) {}
    }
}

struct PermissionRow: View {
    let title: String
    let status: PermissionsService.Status
    let kind: PermissionsService.Kind

    /// Requests the permission, where the system offers a way to ask for it.
    let onRequest: () -> Void

    var body: some View {
        if status == .granted {
            Text("\(symbol) \(title): надано")
        } else if status == .undetermined {
            // Never send the user to System Settings for a permission that has not
            // been requested yet: macOS does not list an app there until it asks
            // once, so the button would open a panel the app is absent from.
            if kind == .microphone {
                Button("\(symbol) \(title): не запитано — запитати зараз") {
                    bringAppToFront()
                    onRequest()
                }
            } else {
                // System audio has no public request API — the prompt appears when
                // the first tap is created, i.e. when a recording starts.
                Text("\(symbol) \(title): буде запитано при першому записі")
            }
        } else {
            Button("\(symbol) \(title): відкликано — відкрити налаштування…") {
                guard let url = kind.settingsURL else { return }
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var symbol: String {
        switch status {
        case .granted: return "🟢"
        case .denied: return "🔴"
        case .undetermined: return "🟡"
        }
    }

    private var label: String {
        switch status {
        case .granted: return "надано"
        case .denied: return "відкликано"
        case .undetermined: return "не запитано"
        }
    }
}

enum TimeFormatting {
    /// `ГГ:ХХ:СС` — the recording duration has to be readable at a glance.
    static func elapsed(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

enum Updates {
    /// No Sparkle: without an Apple Developer signature an auto-updater is not
    /// practical, so "Перевірити оновлення" just opens the Releases page.
    static let releasesURL = URL(string: "https://github.com/volodeveth/STLTH-Recorder-for-macOS/releases/latest")!

    static func openReleasesPage() {
        NSWorkspace.shared.open(releasesURL)
    }
}
