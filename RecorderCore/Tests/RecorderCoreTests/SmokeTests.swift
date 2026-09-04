import Testing
@testable import RecorderCore

@Suite("Smoke")
struct SmokeTests {
    @Test("Package version is exposed")
    func version() {
        #expect(RecorderCore.version == "0.1.0")
    }
}
