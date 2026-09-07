import XCTest
@testable import KeeneticControl

final class RouterBackupIdentityTests: XCTestCase {
    func testRCIRoutersWithSameLegacySSHHostHaveSeparateBackupNamesAndFilters() {
        let first = RouterProfile(host: "192.168.1.1", webURL: "https://first.example/", transport: .http)
        let second = RouterProfile(host: "192.168.1.1", webURL: "https://second.example:8443/rci", transport: .http)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let identifier = UUID()
        let files = [first, second].map {
            URL(fileURLWithPath: "/tmp/" + Backups.runningConfigFilename(
                host: $0.backupHost, date: date, identifier: identifier))
        }

        XCTAssertEqual(first.backupHost, "first.example")
        XCTAssertEqual(second.backupHost, "second.example:8443")
        XCTAssertNotEqual(files[0], files[1], "Router identity must separate filenames even at the same instant")
        for (index, profile) in [first, second].enumerated() {
            let filtered = files.filter { Backups.host(of: $0) == Backups.safeHost(profile.backupHost) }
            XCTAssertEqual(filtered, [files[index]])
        }
    }

    func testSSHAndUnchangedRCIHostsKeepLegacyBackupPrefixes() {
        let ssh = RouterProfile(host: "My_Router.local", port: 2222,
                                webURL: "https://unused.example/", transport: .ssh)
        XCTAssertEqual(ssh.backupHost, ssh.host)
        let legacy = URL(fileURLWithPath: "/tmp/My_Router.local_2024-01-02_03-04-05_running-config.txt")
        XCTAssertEqual(Backups.host(of: legacy), Backups.safeHost(ssh.backupHost))

        for address in ["http://my_router.local/", "http://my_router.local:80/", "https://my_router.local:443/"] {
            let rci = RouterProfile(host: ssh.host, webURL: address, transport: .http)
            XCTAssertEqual(rci.backupHost, ssh.host, "Default ports and case normalization must preserve legacy names")
        }
    }

    func testRCINondefaultPortsSeparateRoutersAndIPv6KeepsLegacyHost() {
        let first = RouterProfile(webURL: "http://router.example:8080/", transport: .http)
        let second = RouterProfile(webURL: "http://router.example:8081/", transport: .http)
        XCTAssertNotEqual(Backups.safeHost(first.backupHost), Backups.safeHost(second.backupHost))

        let ipv6 = RouterProfile(host: "2001:db8::1", webURL: "http://[2001:db8::1]/", transport: .http)
        XCTAssertEqual(ipv6.backupHost, ipv6.host)
        let withPort = RouterProfile(host: ipv6.host, webURL: "http://[2001:db8::1]:8080/", transport: .http)
        XCTAssertNotEqual(Backups.safeHost(withPort.backupHost), Backups.safeHost(ipv6.backupHost))
    }
}
