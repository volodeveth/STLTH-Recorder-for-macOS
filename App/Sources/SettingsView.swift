import RecorderCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var models: ModelInstaller
    @AppStorage("createMixdown") private var createMixdown = true
    @AppStorage("autoTranscribe") private var autoTranscribe = true
    @AppStorage("deleteAudioAfterTranscription") private var deleteAudio = false
    @AppStorage("remindAboutMeetings") private var remindAboutMeetings = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Загальне") {
                Toggle("Запускати при вході в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        apply(launchAtLogin: newValue)
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Записи") {
                Toggle("Створювати зведений файл для прослуховування", isOn: $createMixdown)
                Text("Після кожної зустрічі поруч із доріжками з\u{2019}являється session.m4a — "
                     + "ви ліворуч, співрозмовник праворуч. Вихідні mic.caf і system.caf лишаються "
                     + "недоторканими, якщо не увімкнено видалення після розпізнавання.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Тека сесій") {
                    Button("Показати у Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([SessionStore.defaultRoot])
                    }
                }
                LabeledContent("Вільне місце") {
                    Text(freeSpaceDescription)
                }
            }

            Section("Транскрибація") {
                Toggle("Розпізнавати мову після кожного запису", isOn: $autoTranscribe)
                Text("Працює у фоні й повністю на цьому Mac — по одній сесії за раз. "
                     + "Займає приблизно стільки ж часу, скільки тривала розмова.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if autoTranscribe && !Transcriber.isAvailable {
                    // The toggle stays available, but without models it does nothing —
                    // better to say so here than let the user wait for a transcript
                    // that will not come.
                    Text("Спершу завантажте моделі — нижче або в меню будь-якої сесії.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Видаляти аудіо після розпізнавання", isOn: $deleteAudio)
                Text("Вихідні mic.caf і system.caf видаляються назавжди; лишаються транскрипт, "
                     + "зведений файл і meta.json. Година розмови — це ~990 МБ проти ~43 МБ. "
                     + "Спрацьовує лише тоді, коли в транскрипті є мовлення.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if deleteAudio && !createMixdown {
                    // Together with the mixdown off this leaves nothing of a session but
                    // text. A legitimate choice — but one to make with open eyes, not to
                    // discover a week later.
                    Text("Зведений файл вимкнено — після видалення доріжок від сесії "
                         + "лишиться тільки текст.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                LabeledContent("Моделі розпізнавання") {
                    switch models.state {
                    case .ready:
                        Text(ByteCountFormatter.string(
                            fromByteCount: ModelInstaller.installedBytes(in: models.directory),
                            countStyle: .binary))
                    case .downloading(_, let completed, let total):
                        Text("завантаження — \(Int(Double(completed) / Double(max(total, 1)) * 100))%")
                    case .notInstalled, .failed:
                        Text("не встановлені").foregroundStyle(.secondary)
                    }
                }
                if models.state == .notInstalled, Transcriber.isAvailable {
                    // 1.2.0 shipped turbo. It still works, so nothing is broken — but
                    // the person should know why a download is being asked for.
                    Text("Знайдено попередню модель (turbo) — розпізнавання працює на ній. "
                         + "Після завантаження нової стара зітреться сама.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .ready = models.state {
                    Button("Видалити моделі") { try? models.removeModels() }
                } else if case .downloading = models.state {
                    Button("Скасувати завантаження") { models.cancel() }
                } else {
                    Button("Завантажити моделі…") { models.install() }
                }
            }

            Section("Про застосунок") {
                LabeledContent("Версія", value: appVersion)
                // The old wording said the app makes no network requests except the
                // update check. Downloading the models is a second one, so the promise
                // now names both rather than quietly acquiring an exception.
                Text("Аудіо зберігається лише на цьому Mac і нікуди не надсилається — зокрема під час розпізнавання. Мережа використовується у двох випадках, обидва за вашим кліком: перевірка оновлень і завантаження моделей розпізнавання.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Нагадування") {
                Toggle("Нагадувати про незаписані зустрічі", isOn: $remindAboutMeetings)
                Text("Коли Zoom, Meet або інший застосунок для дзвінків починає "
                     + "використовувати мікрофон, STLTH Recorder for macOS питає, чи вмикати запис. "
                     + "Рішення завжди за вами — сам він не стартує.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func apply(launchAtLogin enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "Не вдалося змінити автозапуск: \(error.localizedDescription)"
        }
    }

    private var freeSpaceDescription: String {
        let bytes = DiskGuard.freeBytes(at: SessionStore.defaultRoot)
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let minutes = DiskGuard.estimatedMinutesRemaining(freeBytes: bytes)
        return "\(formatted) (≈ \(minutes) хв запису)"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}
