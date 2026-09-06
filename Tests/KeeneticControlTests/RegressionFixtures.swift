import Foundation
@testable import KeeneticControl

enum RegressionFixtures {
    static let sampleConfig = """
    interface Wireguard0
        description NL-VPN
        wireguard listen-port 51820
        wireguard peer aBcDeFgH1234567890abcdefghijklmnopqrstuv=
            endpoint 203.0.113.9:51820
            keepalive-interval 25
            allow-ips 0.0.0.0 0.0.0.0
            connect
            !
        ip address 10.7.0.2 255.255.255.0
        ip mtu 1420
        up
    !
    interface ISP
        description Provider
    !
    object-group fqdn domain-list0
        description "kinopub"
        include kinopub.tv
        include api.kinopub.me
        include 5.61.239.10
    !
    object-group fqdn domain-list1
        description "itdog ru inside 1"
        include rutracker.org
        include 2ch.hk
    !
    dns-proxy
        route object-group domain-list0 Wireguard0 auto
    !
    dns-proxy route object-group domain-list1 Wireguard0 auto
    !
    ip route 10.50.0.0 255.255.0.0 Wireguard0 metric 10 auto !корпоративка
    ip route default ISP auto
    ipv6 route 2001:db8::/32 Wireguard0
    ip route 203.0.113.77 ISP reject
    !
    """

    static let liveJSON: [String: Any] = [
        "Wireguard0": [
            "id": "Wireguard0",
            "description": "Dataforest",
            "type": "Wireguard",
            "state": "up",
            "connected": "yes",
            "details": ["ping-check": ["status": "running"]],
            "wireguard": ["peer": [[
                "public-key": "abc=",
                "remote-endpoint-address": "1.2.3.4:51820",
                "online": true,
                "rxbytes": 1024,
                "txbytes": 2048,
                "last-handshake": 12,
            ]]],
        ],
        "Wireguard1": [
            "id": "Wireguard1",
            "state": "up",
            "details": ["ping-check": ["status": "stopped"]],
            "wireguard": ["peer": [
                "public-key": "one=",
                "online": false,
                "last-handshake": 2_147_483_647,
            ]],
        ],
        "Wireguard2": ["id": "Wireguard2", "state": "up"],
    ]
}
