import RecorderCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var models: ModelInstaller
    @AppStorage("createMixdown") private var createMixdown = true
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
                     + "радник ліворуч, клієнт праворуч. Вихідні mic.caf і system.caf лишаються "
                     + "недоторканими.")
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
