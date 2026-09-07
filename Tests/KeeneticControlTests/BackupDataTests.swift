import XCTest
@testable import KeeneticControl

final class BackupDataTests: XCTestCase {
    func testSnapshotsWithinSameSecondHaveDistinctNamesAndKeepHostIdentity() {
        let date = Date(timeIntervalSince1970: 1_783_340_000)
        let first = Backups.runningConfigFilename(host: "my_router.local", date: date)
        let second = Backups.runningConfigFilename(host: "my_router.local", date: date)
        XCTAssertNotEqual(first, second)
        for name in [first, second] {
            XCTAssertEqual(Backups.host(of: URL(fileURLWithPath: "/backups/" + name)), "my_router.local")
        }
    }

    func testDamagedEncryptedHeaderCannotBeInterpretedAsEmptyConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupted = directory.appendingPathComponent("damaged.kcbackup")
        try Data("KCBX".utf8).write(to: corrupted)
        XCTAssertThrowsError(try SecureBackup.read(corrupted)) { error in
            guard case SecureBackupError.invalidContainer = error else {
                return XCTFail("Wrong error: \(error)")
            }
        }
        let legacy = directory.appendingPathComponent("legacy.txt")
        let text = "object-group fqdn restored\n    include example.com\n"
        try Data(text.utf8).write(to: legacy)
        XCTAssertEqual(try SecureBackup.read(legacy), text)
    }
}
