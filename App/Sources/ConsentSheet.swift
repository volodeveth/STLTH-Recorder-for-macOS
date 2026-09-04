import RecorderCore
import SwiftUI

/// Consent is confirmed *before* any audio is captured, and the moment of
/// confirmation is stored in meta.json (ТЗ F-4).
struct ConsentSheet: View {
    let diskLevel: DiskGuard.Level
    let onConfirm: (Date) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Підтвердження згоди")
                .font(.headline)

            Text("Підтвердіть, що клієнт дав згоду на запис зустрічі.")
                .fixedSize(horizontal: false, vertical: true)

            if diskLevel != .ok {
                Label(diskWarning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(diskLevel == .critical ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Аудіо зберігається лише на цьому Mac і нікуди не надсилається.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Скасувати", role: .cancel) { onCancel() }
                Spacer()
                Button("Підтверджую — почати запис") { onConfirm(Date()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(diskLevel == .critical)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var diskWarning: String {
        let free = DiskGuard.freeBytes(at: SessionStore.defaultRoot)
        let minutes = DiskGuard.estimatedMinutesRemaining(freeBytes: free)
        switch diskLevel {
        case .critical:
            return "Замало місця на диску — запис неможливий. Звільніть місце та спробуйте знову."
        case .low:
            return "Мало місця на диску: вистачить приблизно на \(minutes) хв запису."
        case .ok:
            return ""
        }
    }
}
