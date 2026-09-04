import AppKit
import Foundation
import RecorderCore
import SwiftUI

/// Produces the listening mixdown in the background.
///
/// Lives in the app layer, not the core, for one reason: whether to mix at all is a
/// setting, and the core has no business reading `@AppStorage`.
///
/// The mixdown is derived. Its failure is logged and forgotten — it must never make a
/// session look unsuccessful, never block `stop()`, never hold up the UI.
@MainActor
final class MixdownService: ObservableObject {

    /// Sessions being mixed right now, so the menu can say so.
    @Published private(set) var inProgress: Set<UUID> = []

    @AppStorage("createMixdown") var isEnabled = true

    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    func hasMix(for meta: SessionMeta) -> Bool {
        SessionMixer.mixExists(in: directory(for: meta))
    }

    func isMixing(_ meta: SessionMeta) -> Bool {
        inProgress.contains(meta.sessionId)
    }

    func mixURL(for meta: SessionMeta) -> URL {
        SessionMixer.mixURL(in: directory(for: meta))
    }

    /// Mix automatically after a session is finished — only if the setting allows it.
    func mixAfterRecording(_ meta: SessionMeta?) {
        guard isEnabled, let meta else { return }
        mix(meta, announce: false)
    }

    /// Mix sessions a crash left behind, after their CAF headers have been repaired.
    func mixRecovered(_ directories: [URL]) {
        guard isEnabled else { return }
        for dir in directories where !SessionMixer.mixExists(in: dir) {
            Task.detached(priority: .background) { [store] in
                guard let url = try? SessionMixer.mix(sessionDir: dir) else { return }
                await MainActor.run { store.noteMix(at: dir, fileName: url.lastPathComponent) }
            }
        }
    }

    /// Mix on demand, from the menu.
    func mix(_ meta: SessionMeta, announce: Bool = true) {
        guard !inProgress.contains(meta.sessionId) else { return }
        inProgress.insert(meta.sessionId)

        let dir = directory(for: meta)
        Task.detached(priority: .utility) { [store] in
            let result = Result { try SessionMixer.mix(sessionDir: dir) }
            await MainActor.run {
                self.inProgress.remove(meta.sessionId)
                switch result {
                case .success(let url):
                    store.noteMix(at: dir, fileName: url.lastPathComponent)
                    if announce { NSWorkspace.shared.open(url) }
                case .failure(let error):
                    NSLog("Зведений файл не створено: %@", error.localizedDescription)
                    if announce {
                        let alert = NSAlert()
                        alert.messageText = "Не вдалося створити зведений файл"
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }
        }
    }

    private func directory(for meta: SessionMeta) -> URL {
        store.root.appendingPathComponent(meta.sessionId.uuidString, isDirectory: true)
    }
}
