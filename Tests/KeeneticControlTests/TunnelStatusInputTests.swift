import XCTest
@testable import KeeneticControl

final class TunnelStatusInputTests: XCTestCase {
    private func state() -> RouterState {
        RouterState(pingCheckProfiles: [PingCheckProfile(name: "primary", host: "one.example",
                                                       mode: .connect, port: 443)],
                    pingCheckBindings: ["Wireguard0": PingCheckBinding(profile: "primary", restart: false)])
    }

    func testEditingTargetOrPortOfSameProfileInvalidatesRead() {
        let router = RouterProfile(host: "fixture.invalid")
        let initial = state()
        let input = TunnelStatusInput(router: router, interface: "Wireguard0", state: initial)

        var targetChanged = initial
        targetChanged.pingCheckProfiles[0].host = "two.example"
        XCTAssertNotEqual(input, TunnelStatusInput(router: router, interface: "Wireguard0", state: targetChanged))

        var portChanged = initial
        portChanged.pingCheckProfiles[0].port = 8443
        XCTAssertNotEqual(input, TunnelStatusInput(router: router, interface: "Wireguard0", state: portChanged))

        var timeoutChanged = initial
        timeoutChanged.pingCheckProfiles[0].timeout = 7
        XCTAssertNotEqual(input, TunnelStatusInput(router: router, interface: "Wireguard0", state: timeoutChanged))
    }

    func testChangingBindingRestartInvalidatesRead() {
        let router = RouterProfile(host: "fixture.invalid")
        var snapshot = state()
        let input = TunnelStatusInput(router: router, interface: "Wireguard0", state: snapshot)
        snapshot.pingCheckBindings["Wireguard0"]?.restart = true
        XCTAssertNotEqual(input, TunnelStatusInput(router: router, interface: "Wireguard0", state: snapshot))
    }

    func testLiveReadTimeAndCountersDoNotRestartMonitor() {
        let router = RouterProfile(host: "fixture.invalid")
        var snapshot = state()
        snapshot.readAt = Date(timeIntervalSince1970: 100)
        let input = TunnelStatusInput(router: router, interface: "Wireguard0", state: snapshot)
        snapshot.readAt = Date(timeIntervalSince1970: 120)
        snapshot.interfaces["Wireguard0"] = KeeneticInterface(ident: "Wireguard0", pingCheckStatus: "running",
                                                           pingCheckSuccessCount: 15)
        XCTAssertEqual(input, TunnelStatusInput(router: router, interface: "Wireguard0", state: snapshot))
    }
}
