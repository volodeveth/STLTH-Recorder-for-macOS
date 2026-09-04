import AppKit
import RecorderCore
import SwiftUI

/// "Останні записи": open the session folder in Finder or delete it (ТЗ F-4).
struct RecentSessionsMenu: View {
    /// Observed, not just borrowed: the list has to reload when a recording ends.
    @ObservedObject var controller: RecorderController
    /// Drives the menu item between "увімкнути", a percentage, and "Транскрибувати".
    @ObservedObject var models: ModelInstaller
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var mixdown: MixdownService
    @State private var sessions: [SessionMeta] = []
    /// Session currently being transcribed — the menu has no room for a progress bar,
    /// so the item itself reports the state.
    @State private var transcribing: UUID?
    @State private var transcriptionError: String?

    private var store: SessionStore { controller.store }

    var body: some View {
        Menu("Останні записи") {
            if sessions.isEmpty {
                Text("Записів ще немає")
            } else {
                ForEach(sessions.prefix(5), id: \.sessionId) { meta in
                    Menu(title(for: meta)) {
                        listenButton(for: meta)
                        Button("Показати у Finder") { reveal(meta) }
                        transcribeButton(for: meta)
                        Button("Видалити запис…", role: .destructive) { confirmDelete(meta) }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        // MenuBarExtra builds its content once and keeps it alive, so `onAppear`
        // fires exactly one time — the list froze as it was at launch and a session
        // recorded a minute later simply never appeared. Reloading on every state
        // transition covers the case that matters: a recording just finished.
        .onChange(of: controller.state) { _, _ in reload() }
    }

    @ViewBuilder
    private func listenButton(for meta: SessionMeta) -> some View {
        if mixdown.isMixing(meta) {
            Text("Зводиться…")
        } else if mixdown.hasMix(for: meta) {
            Button("Прослухати розмову") { NSWorkspace.shared.open(mixdown.mixURL(for: meta)) }
        } else {
            // Sessions recorded before mixdowns existed, or ones whose mix failed.
            Button("Створити зведений файл") { mixdown.mix(meta) }
        }
    }

    @ViewBuilder
    private func transcribeButton(for meta: SessionMeta) -> some View {
        if transcribing == meta.sessionId {
            Text("Транскрибується…")
        } else if hasTranscript(meta) {
            Button("Показати транскрипт") { revealTranscript(meta) }
        } else if Transcriber.isAvailable {
            Button("Транскрибувати") { transcribe(meta) }
        } else if case .downloading(_, let completed, let total) = models.state {
            Text("Завантаження моделей — \(Int(Double(completed) / Double(max(total, 1)) * 100))%")
        } else {
            // A button, not a label. This used to be plain `Text` naming the missing
            // dependency and pointing at `scripts/setup-transcription.sh` — a file that
            // does not exist on a machine which installed the DMG. It stated a problem
            // and offered no way out of it.
            Button("Увімкнути транскрибацію…") {
                bringAppToFront()
                openWindow(id: TranscriptionSetupWindow.id)
            }
        }
    }

    private func hasTranscript(_ meta: SessionMeta) -> Bool {
        FileManager.default.fileExists(
            atPath: directory(for: meta).appendingPathComponent("transcript.md").path)
    }

    private func revealTranscript(_ meta: SessionMeta) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [directory(for: meta).appendingPathComponent("transcript.md")])
    }

    private func transcribe(_ meta: SessionMeta) {
        transcribing = meta.sessionId
        let directory = directory(for: meta)
        Task.detached(priority: .utility) {
            do {
                let transcript = try Transcriber.transcribe(sessionDir: directory)
                await MainActor.run {
                    transcribing = nil
                    NSWorkspace.shared.activateFileViewerSelecting([transcript])
                }
            } catch {
                await MainActor.run {
                    transcribing = nil
                    transcriptionError = error.localizedDescription
                    let alert = NSAlert()
                    alert.messageText = "Не вдалося транскрибувати"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    private func reload() {
        sessions = store.list()
    }

    private func title(for meta: SessionMeta) -> String {
        let date = meta.startedAt.formatted(date: .abbreviated, time: .shortened)
        let duration = TimeFormatting.elapsed(Double(meta.durationMs) / 1000)
        let suffix = meta.status == .interrupted ? " — перервана" : ""
        return "\(date) · \(duration)\(suffix)"
    }

    private func directory(for meta: SessionMeta) -> URL {
        store.root.appendingPathComponent(meta.sessionId.uuidString, isDirectory: true)
    }

    private func reveal(_ meta: SessionMeta) {
        NSWorkspace.shared.activateFileViewerSelecting([directory(for: meta)])
    }

    private func confirmDelete(_ meta: SessionMeta) {
        let alert = NSAlert()
        alert.messageText = "Видалити запис?"
        alert.informativeText = "Аудіофайли та метадані сесії від \(meta.startedAt.formatted()) буде видалено безповоротно."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Видалити")
        alert.addButton(withTitle: "Скасувати")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        try? store.delete(id: meta.sessionId)
        reload()
    }
}
