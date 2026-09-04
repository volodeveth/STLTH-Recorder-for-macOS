import Foundation
import Testing
@testable import RecorderCore

@Suite("DiskGuard")
struct DiskGuardTests {

    @Test("Free space on a real volume is reported")
    func reportsFreeSpace() {
        let bytes = DiskGuard.freeBytes(at: FileManager.default.temporaryDirectory)
        #expect(bytes > 0)
    }

    @Test("A path under an existing volume answers even when the path is missing")
    func nonexistentPathResolvesToItsVolume() {
        // This test used to assert 0 — and that assertion was the bug, written down.
        // "/no/such/volume/at/all" still lives on the root volume, so the honest
        // answer is the free space of "/", not "the disk is full".
        let bytes = DiskGuard.freeBytes(at: URL(fileURLWithPath: "/no/such/volume/at/all"))
        #expect(bytes > 0)
        #expect(DiskGuard.level(forFreeBytes: bytes) != .critical)
    }

    @Test("Levels map to the thresholds from the spec")
    func levelsFollowThresholds() {
        // < 200 MB — recording must stop
        #expect(DiskGuard.level(forFreeBytes: 100 * 1024 * 1024) == .critical)
        // < 1 GB — warn before starting
        #expect(DiskGuard.level(forFreeBytes: 500 * 1024 * 1024) == .low)
        #expect(DiskGuard.level(forFreeBytes: 5 * 1024 * 1024 * 1024) == .ok)
    }

    @Test("Boundaries are inclusive on the safe side")
    func boundariesAreSafe() {
        #expect(DiskGuard.level(forFreeBytes: DiskGuard.criticalThreshold) == .low)
        #expect(DiskGuard.level(forFreeBytes: DiskGuard.criticalThreshold - 1) == .critical)
        #expect(DiskGuard.level(forFreeBytes: DiskGuard.lowThreshold) == .ok)
        #expect(DiskGuard.level(forFreeBytes: DiskGuard.lowThreshold - 1) == .low)
    }

    @Test("Recording minutes remaining are estimated from the real bitrate")
    func estimatesRemainingMinutes() {
        // 48000 Hz × 16 bit × (1 + 2) channels = 288 000 B/s ≈ 16.5 MB/min
        let oneHour = Int64(288_000 * 3600)
        let minutes = DiskGuard.estimatedMinutesRemaining(freeBytes: oneHour)
        #expect(minutes >= 58 && minutes <= 62)
    }
}

extension DiskGuardTests {

    /// On a fresh install the sessions folder does not exist yet, and neither
    /// `volumeAvailableCapacityForImportantUsage` nor `attributesOfFileSystem`
    /// answers for a path that is not there — both fail, `freeBytes` returned 0, and
    /// the consent sheet refused to record on a Mac with 419 GB free.
    @Test("Free space is known for a path that does not exist yet")
    func freeSpaceKnownForMissingPath() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("stlth-\(UUID().uuidString)")
            .appendingPathComponent("Sessions")
            .appendingPathComponent("deeper")

        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(DiskGuard.freeBytes(at: missing) > 0)
        #expect(DiskGuard.level(at: missing) != .critical)
    }

    @Test("A path whose whole tree is missing still resolves to its volume")
    func freeSpaceResolvesThroughSeveralMissingLevels() {
        let deep = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/STLTHRecorder/Sessions")
        // Whether or not it exists today, the guard must answer for it.
        #expect(DiskGuard.freeBytes(at: deep) > 0)
    }
}
