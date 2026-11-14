import Foundation
import I2SCore

/// Runs the core's checks on Windows and Linux (the Mac's self-test runs the
/// same ones): `swift run I2SCoreCheck`. Exits non-zero if any fail.
@main
struct CoreCheckRunner {
    static func main() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("i2s-core-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        print("i2s core check")
        let failed = dir.path.withCString { i2s_core_check($0) }
        if failed < 0 { print("Core checks are only built into debug builds."); exit(2) }
        print(failed == 0 ? "All core checks passed." : "\(failed) core check(s) failed.")
        exit(failed == 0 ? 0 : 1)
    }
}
