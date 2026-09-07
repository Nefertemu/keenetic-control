import XCTest
@testable import KeeneticControl

@MainActor
final class ProbeHistoryTests: XCTestCase {
    func testGraphDoesNotMixTargetsMethodsAndPorts() {
        let store = TunnelHealthStore.shared, router = UUID(), now = Date()
        func record(_ target: String, _ method: InterfaceProbeMethod, _ port: Int?, _ latency: Double) {
            store.record(routerID: router, result: InterfacePingResult(
                interface: "Wireguard0", target: target, method: method, port: port, source: nil,
                transmitted: 1, received: 1, rtt: [latency], checkedAt: now, error: nil))
        }
        record("one.example", .icmp, nil, 1)
        record("two.example", .icmp, nil, 2)
        record("one.example", .tcp, 443, 3)
        record("one.example", .tcp, 8443, 4)
        let icmp = store.latencySamples(routerID: router, interface: "Wireguard0",
                                        target: "one.example", method: .icmp, now: now)
        let tcp = store.latencySamples(routerID: router, interface: "Wireguard0",
                                       target: "one.example", method: .tcp, port: 443, now: now)
        XCTAssertEqual(icmp.compactMap(\.latencyMS), [1])
        XCTAssertEqual(tcp.compactMap(\.latencyMS), [3])
    }

    func testOldHistoryWithoutPortStillDecodes() throws {
        let sample = TunnelHealthSample(state: .healthy, interfaceUp: true,
                                        handshakeFresh: true, pingStatus: nil,
                                        latencyMS: 1, probeTarget: "one.example", probeMethod: "icmp")
        let data = try JSONEncoder().encode(sample)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "probePort")
        let decoded = try JSONDecoder().decode(TunnelHealthSample.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.probePort)
        XCTAssertEqual(decoded.probeTarget, "one.example")
    }

    func testDiagnosticsInputChangesWhenConfigurationChanges() {
        let context = RouterPresentationContext(RouterProfile(host: "fixture.invalid"))
        let old = DiagnosticsInput(router: context, interface: "Wireguard0",
                                   target: "example.org", configText: "interface Wireguard0\n mtu 1400")
        var new = old
        new.configText = "interface Wireguard0\n mtu 1280"
        XCTAssertNotEqual(new, old, "MTU changes must invalidate the diagnostic report")
    }
}
