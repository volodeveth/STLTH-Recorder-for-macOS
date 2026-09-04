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
    /// Owns the queue and the "Транскрибується…" state — the menu has no room for a
    /// progress bar, so the item itself reports it, for automatic runs as well.
    @ObservedObject var transcription: TranscriptionService
    @State private var sessions: [SessionMeta] = []

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
        // Audio removal rewrites meta.json after the fact; the list has to show it.
        .onChange(of: transcription.inProgress) { _, _ in reload() }
    }

    @ViewBuilder
    private func listenButton(for meta: SessionMeta) -> some View {
        if mixdown.isMixing(meta) {
            Text("Зводиться…")
        } else if mixdown.hasMix(for: meta) {
            Button("Прослухати розмову") { NSWorkspace.shared.open(mixdown.mixURL(for: meta)) }
        } else if transcription.hasAudio(meta) {
            // Sessions recorded before mixdowns existed, or ones whose mix failed.
            Button("Створити зведений файл") { mixdown.mix(meta) }
        } else {
            // Not a broken session: the tracks were removed on purpose after
            // transcription, and there is nothing left to mix from.
            Text("Аудіо видалено після транскрибації")
        }
    }

    @ViewBuilder
    private func transcribeButton(for meta: SessionMeta) -> some View {
        if transcription.isTranscribing(meta) {
            Text("Транскрибується…")
        } else if transcription.hasTranscript(meta) {
            Button("Показати транскрипт") { revealTranscript(meta) }
        } else if !transcription.hasAudio(meta) {
            // Offering transcription here would promise what can no longer be done.
            EmptyView()
        } else if Transcriber.isAvailable {
            Button("Транскрибувати") { transcription.transcribe(meta) }
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

    private func revealTranscript(_ meta: SessionMeta) {
        NSWorkspace.shared.activateFileViewerSelecting([transcription.transcriptURL(for: meta)])
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
