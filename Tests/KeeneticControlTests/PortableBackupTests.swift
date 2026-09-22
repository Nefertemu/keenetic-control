import CryptoKit
import XCTest
@testable import KeeneticControl

final class PortableBackupTests: XCTestCase {
    private let password = "Только для теста 937!"
    private let text = "hostname test-router\ninterface Wireguard0\n    description top-secret\n!\n"

    func testReadsContainerUsingIndependentlyComputedPBKDF2SHA256Vector() throws {
        // Python hashlib.pbkdf2_hmac('sha256', b'test-password-123', bytes(range(16)), 600000, 32).
        let keyBytes: [UInt8] = [0x7a, 0xa0, 0x64, 0xf8, 0xed, 0x55, 0x66, 0x7e,
            0x6b, 0x4f, 0x95, 0x54, 0x51, 0xcc, 0x33, 0xba, 0x6d, 0xa3, 0x3a, 0xfb,
            0x76, 0x1a, 0x02, 0x1d, 0xa0, 0x14, 0xff, 0x52, 0x4d, 0xed, 0xdf, 0x14]
        let header = Data([0x4b, 0x43, 0x50, 0x42, 0x01, 0x00, 0x09, 0x27, 0xc0] + Array(UInt8(0)...UInt8(15)))
        let sealed = try AES.GCM.seal(Data(text.utf8), using: SymmetricKey(data: keyBytes),
                                      nonce: AES.GCM.Nonce(data: Data(repeating: 7, count: 12)), authenticating: header)
        XCTAssertEqual(try PortableBackup.open(header + XCTUnwrap(sealed.combined), password: "test-password-123"), text)
    }

    func testRoundTripUsesRandomSaltAndNonceAndNeedsNoKeychain() throws {
        let first = try PortableBackup.seal(text, password: password)
        let second = try PortableBackup.seal(text, password: password)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first[9..<25], second[9..<25], "Fresh independent salts")
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("top-secret"))
        XCTAssertEqual(try PortableBackup.open(first, password: password), text)
        XCTAssertEqual(try PortableBackup.open(second, password: password), text)
    }

    func testWrongPasswordAndHeaderOrCiphertextTamperingAreRejected() throws {
        let data = try PortableBackup.seal(text, password: password)
        XCTAssertThrowsError(try PortableBackup.open(data, password: "another-password-123"))
        for offset in [0, 4, 9, 25, data.count - 1] {
            var modified = data; modified[offset] ^= 1
            XCTAssertThrowsError(try PortableBackup.open(modified, password: password), "Accepted tamper at \(offset)")
        }
        XCTAssertThrowsError(try PortableBackup.open(Data(data.dropLast()), password: password))
    }

    func testHostileDerivationCostsAreRejectedBeforeKDF() throws {
        var data = try PortableBackup.seal(text, password: password)
        for offset in 5..<9 { data[offset] = 0xff }
        XCTAssertThrowsError(try PortableBackup.open(data, password: password)) { error in
            guard case PortableBackup.Failure.invalidFile = error else { return XCTFail("Unexpected \(error)") }
        }
        for offset in 5..<9 { data[offset] = 0 }
        XCTAssertThrowsError(try PortableBackup.open(data, password: password))
    }

    func testRefusesWeakPasswordsAndInvalidConfigurations() throws {
        XCTAssertThrowsError(try PortableBackup.seal(text, password: "short"))
        XCTAssertThrowsError(try PortableBackup.seal(text, password: String(repeating: "x", count: 1025)))
        XCTAssertThrowsError(try PortableBackup.seal("", password: password))
        XCTAssertThrowsError(try PortableBackup.seal("<html>Login</html>", password: password))
    }

    func testRefusesOversizedFileBeforeReadingOrDerivingKey() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kcportable")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(PortableBackup.maximumFileSize + 1))
        try handle.close()
        XCTAssertThrowsError(try PortableBackup.read(file, password: password)) { error in
            guard case PortableBackup.Failure.invalidFile = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testPortableFileCanBeReadAfterMovingAndIsPrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("export.kcportable")
        let second = directory.appendingPathComponent("moved.kcportable")
        try PortableBackup.write(text, to: first, password: password)
        try FileManager.default.moveItem(at: first, to: second)
        XCTAssertEqual(try PortableBackup.read(second, password: password), text)
        let attributes = try FileManager.default.attributesOfItem(atPath: second.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
