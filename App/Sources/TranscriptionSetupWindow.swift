import RecorderCore
import SwiftUI

/// Asks before downloading half a gigabyte, then shows it happening.
///
/// A `MenuBarExtra` cannot present a sheet — the menu closes the moment it loses focus,
/// taking any modal with it. The consent flow already solved this with a `Window` scene
/// opened through `openWindow`, and this follows the same path.
struct TranscriptionSetupWindow: View {
    @ObservedObject var models: ModelInstaller
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Транскрибація")
                .font(.title2.weight(.semibold))

            switch models.state {
            case .notInstalled, .failed:
                explanation
            case .downloading(let file, let completed, let total):
                progress(file: file, completed: completed, total: total)
            case .ready:
                done
            }

            if case .failed(let message) = models.state {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            buttons
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { models.refresh() }
    }

    // MARK: - States

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Розпізнавання працює повністю на цьому Mac. Щоб його увімкнути, "
                 + "потрібно один раз завантажити моделі.")
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ModelInstaller.requiredModels, id: \.name) { model in
                LabeledContent(model.purpose) {
                    Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .binary))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            // The VAD model is 864 KB against 547 MB and reads like a rounding error,
            // so it gets a sentence: without it the transcript fills silence with
            // sentences nobody said, and a meeting is mostly silence.
            Text("Обидві потрібні. Без другої моделі розпізнавання вигадує текст у "
                 + "місцях тиші — а зустріч здебільшого з неї й складається.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Завантажуються **лише моделі**. Аудіо ваших зустрічей нікуди не "
                 + "надсилається — ні зараз, ні під час розпізнавання.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(file: String, completed: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
            HStack {
                Text(file).foregroundStyle(.secondary)
                Spacer()
                Text("\(byteString(completed)) з \(byteString(total))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            Text("Можна закрити це вікно — завантаження триватиме. Якщо перервати, "
                 + "наступна спроба продовжить з того самого місця.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Транскрибація готова", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("У меню: Останні записи → сесія → «Транскрибувати».")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            switch models.state {
            case .notInstalled:
                Button("Не зараз") { dismissWindow(id: TranscriptionSetupWindow.id) }
                Button("Завантажити (\(byteString(ModelInstaller.totalBytes)))") {
                    models.install()
                }
                .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Закрити") { dismissWindow(id: TranscriptionSetupWindow.id) }
                Button("Спробувати ще раз") { models.install() }
                    .keyboardShortcut(.defaultAction)
            case .downloading:
                Button("Скасувати") { models.cancel() }
                Button("Закрити") { dismissWindow(id: TranscriptionSetupWindow.id) }
                    .keyboardShortcut(.defaultAction)
            case .ready:
                Button("Готово") { dismissWindow(id: TranscriptionSetupWindow.id) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    static let id = "transcription-setup"
}
