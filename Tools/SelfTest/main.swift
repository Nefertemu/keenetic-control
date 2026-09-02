import Foundation

var failures = 0
var checks = 0

func check(_ name: String, _ actual: String, _ expected: String) {
    checks += 1
    if actual == expected { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)\n       ждали: \(expected)\n       вышло: \(actual)") }
}

func check(_ name: String, _ actual: [String], _ expected: [String]) {
    check(name, actual.joined(separator: " | "), expected.joined(separator: " | "))
}

func check(_ name: String, _ condition: Bool) {
    checks += 1
    if condition { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}

print("\n== Punycode / IDNA ==")
check("кириллица", Punycode.encode(domain: "пример.рф") ?? "nil", "xn--e1afmkfd.xn--p1ai")
check("ascii не трогаем", Punycode.encode(domain: "example.com") ?? "nil", "example.com")
check("смешанный", Punycode.encode(domain: "почта.example.com") ?? "nil", "xn--80a1acny.example.com")

print("\n== Нормализация доменов ==")
check("hosts-формат", Domains.normalize("0.0.0.0 ads.example.com") ?? "nil", "ads.example.com")
check("adblock", Domains.normalize("||tracker.net^") ?? "nil", "tracker.net")
check("wildcard", Domains.normalize("*.cdn.example.org") ?? "nil", "cdn.example.org")
check("url", Domains.normalize("https://site.example.com/path?a=1") ?? "nil", "site.example.com")
check("точка в конце", Domains.normalize("Example.COM.") ?? "nil", "example.com")
check("подсеть", Domains.normalize("10.1.2.3/16") ?? "nil", "10.1.0.0/16")
check("голый ipv4", Domains.normalize("8.8.8.8") ?? "nil", "8.8.8.8")
check("ipv6 подсеть", Domains.normalize("2a03:2880:f10c::/48") ?? "nil", "2a03:2880:f10c::/48")
check("комментарий отбит", Domains.normalize("# comment") == nil)
check("одна метка отбита", Domains.normalize("localhost") == nil)
check("цифровой tld отбит", Domains.normalize("1.2.3.4.5") == nil)
check("кириллический домен", Domains.normalize("КиноПоиск.рф") ?? "nil", "xn--h1aaecngahu.xn--p1ai")

print("\n== IP-инструменты ==")
check("cidr → адрес+маска", IPTools.ipv4CIDRToAddressMask("10.20.30.40/24").map { "\($0.address) \($0.mask)" } ?? "nil",
      "10.20.30.0 255.255.255.0")
check("маска → префикс", String(IPTools.ipv4MaskToPrefix("255.255.240.0") ?? -1), "20")
check("кривая маска отбита", IPTools.ipv4MaskToPrefix("255.0.255.0") == nil)

print("\n== Разбор running-config ==")
let sampleConfig = """
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

let groups = RouterConfigParser.parseFqdnGroups(sampleConfig)
check("нашли 2 списка", String(groups.count), "2")
check("описание списка", groups["domain-list0"]?.descriptionText ?? "nil", "kinopub")
check("записей в списке", String(groups["domain-list0"]?.includes.count ?? -1), "3")
check("вложенный маршрут подхвачен", groups["domain-list0"]?.isRouted(to: "Wireguard0") ?? false)
check("плоский маршрут подхвачен", groups["domain-list1"]?.isRouted(to: "Wireguard0") ?? false)
check("чужой интерфейс не матчится", !(groups["domain-list0"]?.isRouted(to: "ISP") ?? true))

let interfaces = RouterConfigParser.parseConfigInterfaces(sampleConfig)
check("интерфейсы из конфига", String(interfaces.count), "2")
check("описание интерфейса", interfaces["Wireguard0"]?.descriptionText ?? "nil", "NL-VPN")

print("\n== Имена интерфейсов ==")
check("семейство и номер", "\(InterfaceName.split("Wireguard0"))", "(family: \"Wireguard\", number: Optional(\"0\"))")
check("двузначный номер", InterfaceName.split("Wireguard12").number ?? "nil", "12")
check("без номера — имя целиком", InterfaceName.split("ISP").number == nil)
check("одни цифры не режем", InterfaceName.split("42").family, "42")

var naming = RouterState()
naming.interfaces = [
    "Wireguard0": KeeneticInterface(ident: "Wireguard0", descriptionText: "Dataforest"),
    "Wireguard1": KeeneticInterface(ident: "Wireguard1", descriptionText: "Infomaniak"),
    "Wireguard2": KeeneticInterface(ident: "Wireguard2"),
    "Wireguard5": KeeneticInterface(ident: "Wireguard5"),
    "ISP": KeeneticInterface(ident: "ISP"),
]
check("имя вперёд идентификатора", naming.label(for: "Wireguard0"), "Dataforest · Wireguard0")
check("без примечания — только идентификатор", naming.label(for: "ISP"), "ISP")
check("короткое имя — примечание", naming.shortLabel(for: "Wireguard1"), "Infomaniak")
check("короткое имя без примечания", naming.shortLabel(for: "ISP"), "ISP")
check("сводка по примечаниям",
      naming.targetSummary(["Wireguard0", "Wireguard1"]), "Dataforest, Infomaniak")
check("безымянные сворачиваются в семейство",
      naming.targetSummary(["Wireguard2", "Wireguard5"]), "Wireguard 2, 5")
check("один безымянный — точное имя",
      naming.targetSummary(["Wireguard2"]), "Wireguard2")
check("смешанный случай",
      naming.targetSummary(["Wireguard0", "Wireguard2", "Wireguard5"]),
      "Dataforest, Wireguard 2, 5")
check("неизвестный интерфейс не теряется",
      naming.targetSummary(["Wireguard0", "Tunnel9"]), "Dataforest, Tunnel9")
check("подсказка — по строке на интерфейс",
      naming.targetTooltip(["Wireguard0", "ISP"]), "Dataforest · Wireguard0\nISP")
check("пустой список даёт пустую строку", naming.targetSummary([]), "")

print("\n== Живое состояние интерфейса (форма из кода веб-панели) ==")
// Панель роутера читает details["ping-check"]["status"] и wireguard.peer[].
// Проверяем, что мы разбираем ровно эту форму.
let liveJSON: [String: Any] = [
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
let liveIfaces = RouterConfigParser.parseInterfaceStatus(json: liveJSON)
check("проверка связи прочитана", liveIfaces["Wireguard0"]?.pingCheckStatus ?? "nil", "running")
check("проходящая проверка",
      liveIfaces["Wireguard0"]?.pingCheck(configured: true) == .passing)
check("падающая проверка",
      liveIfaces["Wireguard1"]?.pingCheck(configured: true) == .failing)
check("без профиля состояние не выдумываем",
      liveIfaces["Wireguard0"]?.pingCheck(configured: false) == .notConfigured)
check("роутер молчит — состояние неизвестно, а не «падает»",
      liveIfaces["Wireguard2"]?.pingCheck(configured: true) == .unknown)
check("неизвестное не показывается как состояние роутера",
      !(liveIfaces["Wireguard2"]?.pingCheck(configured: true).isKnown ?? true))
check("а известное показывается",
      liveIfaces["Wireguard0"]?.pingCheck(configured: true).isKnown ?? false)

print("\n== Живой Ping-Check (show ping-check / RCI) ==")
let pingCLI = """
pingcheck:
    profile: vpn
    host: 1.1.1.1
    mode: icmp
    interface: Wireguard0
    fail count: 0
    status: pass
pingcheck:
    profile: backup
    interface: Wireguard1
    fail count: 3
    success count: 1
    status: fail
"""
let parsedPingCLI = PingCheckStatusParser.parseCLI(pingCLI)
check("CLI pass привязан к интерфейсу",
      parsedPingCLI["Wireguard0"]?.state == .passing)
check("CLI счётчик отказов",
      String(parsedPingCLI["Wireguard1"]?.failureCount ?? -1), "3")
check("CLI счётчик успехов",
      String(parsedPingCLI["Wireguard1"]?.successCount ?? -1), "1")
check("CLI fail привязан к интерфейсу",
      parsedPingCLI["Wireguard1"]?.state == .failing)

let pingCLINested = """
pingcheck:
    profile: vpn
            interface:
                     name: Wireguard0
                successcount: 1613
                    failcount: 0
                       status: pass
                  ipcache:
                         host: 1.1.1.1
                    addresses: 1.1.1.1
"""
let parsedPingCLINested = PingCheckStatusParser.parseCLI(pingCLINested)
check("CLI вложенный interface.name разбирается",
      parsedPingCLINested["Wireguard0"]?.state == .passing)
check("CLI вложенный interface сохраняет счётчик",
      String(parsedPingCLINested["Wireguard0"]?.successCount ?? -1), "1613")
check("CLI addresses сохраняется",
      parsedPingCLINested["Wireguard0"]?.resolvedAddresses == ["1.1.1.1"])

let pingJSON: [String: Any] = [
    "pingcheck": [[
        "profile": "vpn",
        "interface": [
            "Wireguard0": [
                "status": "pass",
                "failcount": 0,
                "successcount": 4,
                "ipcache": [["host": "one.one.one.one", "address": "1.1.1.1"]],
            ] as [String: Any],
        ] as [String: Any],
    ] as [String: Any]],
]
let parsedPingJSON = PingCheckStatusParser.parseJSON(pingJSON)
check("RCI pass разбирается",
      parsedPingJSON["Wireguard0"]?.state == .passing)
check("RCI ipcache даёт адрес",
      parsedPingJSON["Wireguard0"]?.resolvedAddresses == ["1.1.1.1"])
check("RCI successcount разбирается",
      String(parsedPingJSON["Wireguard0"]?.successCount ?? -1), "4")

var pingMerged = interfaces
RouterConfigParser.applyPingCheck(parsedPingJSON, to: &pingMerged)
check("живой статус накладывается на интерфейс",
      pingMerged["Wireguard0"]?.pingCheckStatus ?? "nil", "pass")
check("живой профиль накладывается на интерфейс",
      pingMerged["Wireguard0"]?.pingCheckProfile ?? "nil", "vpn")

var diagnosticState = RouterState()
diagnosticState.configText = sampleConfig + "\nip name-server 1.1.1.1 8.8.8.8\n"
diagnosticState.groups = groups
diagnosticState.interfaces = liveIfaces
if var wireguard = diagnosticState.interfaces["Wireguard0"] {
    wireguard.pingCheckResolvedAddresses = ["1.1.1.1"]
    diagnosticState.interfaces["Wireguard0"] = wireguard
}
diagnosticState.pingCheckProfiles = [PingCheckProfile(name: "vpn", host: "1.1.1.1")]
diagnosticState.pingCheckBindings = ["Wireguard0": PingCheckBinding(profile: "vpn", restart: false)]
diagnosticState.staticRoutes = StaticRouteParser.parse(config: sampleConfig)
let diagnostics = RouterDiagnosticsBuilder.build(state: diagnosticState,
                                                 interface: "Wireguard0",
                                                 target: "example.com")
check("DNS-серверы читаются", diagnosticState.nameServers,
      ["1.1.1.1", "8.8.8.8"])

// Реальная строка Keenetic несёт за адресом ещё домен и привязку к
// интерфейсу. Они не серверы и в списке появляться не должны.
var serverState = RouterState()
serverState.configText = """
ip name-server 192.168.248.21 "" on ISP
ip name-server 1.1.1.1 "" on Wireguard0
ip name-server 1.0.0.1
"""
check("за адресом ничего лишнего не подбираем", serverState.nameServers,
      ["192.168.248.21", "1.1.1.1", "1.0.0.1"])
check("диагностика маршрута видит FQDN и static", diagnostics.route.severity == .pass)
check("диагностика MTU видит безопасное значение", diagnostics.mtu.severity == .pass)

// Адреса из статуса Ping-Check относятся к узлу ЕГО профиля. Подписать ими
// произвольную цель — значит утверждать резолвинг, которого не было.
check("чужую цель не выдаём за резолвинг", diagnostics.dns.severity != .pass)
check("и объясняем, чей узел роутер на самом деле резолвит",
      diagnostics.dns.detail.contains("1.1.1.1"))

diagnosticState.pingCheckProfiles = [PingCheckProfile(name: "vpn", host: "example.com")]
let matching = RouterDiagnosticsBuilder.build(state: diagnosticState,
                                              interface: "Wireguard0",
                                              target: "example.com")
check("совпала с профилем — резолвинг подтверждён", matching.dns.severity == .pass)
check("регистр цели не мешает",
      RouterDiagnosticsBuilder.build(state: diagnosticState, interface: "Wireguard0",
                                     target: "Example.COM").dns.severity == .pass)
check("узел профиля определяется",
      RouterDiagnosticsBuilder.pingCheckTarget(state: diagnosticState,
                                               interface: "Wireguard0") ?? "nil",
      "example.com")
check("без профиля узла нет",
      RouterDiagnosticsBuilder.pingCheckTarget(state: diagnosticState,
                                               interface: "Wireguard9") == nil)

// Роутер прислал details, но без ping-check — тоже «не знаем».
let noCheck = RouterConfigParser.parseInterfaceStatus(json: [
    "Wireguard9": ["id": "Wireguard9", "details": ["dsl": ["status": "up"]]],
])
check("details без ping-check — не выдумываем",
      noCheck["Wireguard9"]?.pingCheck(configured: true) == .unknown)

// Ключ лежит глубже, чем ожидалось, — всё равно находим.
let nested = RouterConfigParser.parseInterfaceStatus(json: [
    "Wireguard8": ["id": "Wireguard8",
                   "details": ["ip": ["ping-check": ["status": "running"]]]],
])
check("ping-check найден на глубине",
      nested["Wireguard8"]?.pingCheck(configured: true) == .passing)

check("пустой статус — это не «падает»",
      RouterConfigParser.findPingCheckStatus(["ping-check": [:] as [String: Any]]) == "")
check("нет ключа — nil, а не пустая строка",
      RouterConfigParser.findPingCheckStatus(["details": ["x": 1]]) == nil)

let peer = liveIfaces["Wireguard0"]?.peers.first
check("пир разобран", String(liveIfaces["Wireguard0"]?.peers.count ?? 0), "1")
check("ключ пира", peer?.publicKey ?? "nil", "abc=")
check("точка входа", peer?.endpoint ?? "nil", "1.2.3.4:51820")
check("принято байт", String(peer?.received ?? -1), "1024")
check("отдано байт", String(peer?.sent ?? -1), "2048")
check("возраст рукопожатия", String(peer?.handshakeAge ?? -1), "12")
check("свежее рукопожатие", peer?.isFresh ?? false)

let stale = liveIfaces["Wireguard1"]?.peers.first
check("одиночный пир без массива разобран", stale != nil)
check("сторож 2147483647 — рукопожатия не было", stale?.handshakeAge == nil)
check("офлайновый пир не считается свежим", !(stale?.isFresh ?? true))

var aged = WireGuardPeerState(online: true, handshakeAge: 181)
check("тишина дольше трёх минут — не свежий", !aged.isFresh)
aged.handshakeAge = 180
check("ровно три минуты — ещё свежий", aged.isFresh)

check("самое свежее рукопожатие из нескольких",
      String(KeeneticInterface(ident: "W", peers: [
        WireGuardPeerState(online: true, handshakeAge: 90),
        WireGuardPeerState(online: true, handshakeAge: 12),
      ]).freshestHandshake ?? -1), "12")

check("«только что» для свежих секунд", Format.ago(seconds: 3), "только что")
check("секунды", Format.ago(seconds: 12), "12 с назад")
check("минуты без лишних секунд", Format.ago(seconds: 185), "3 мин назад")
check("часы", Format.ago(seconds: 7300), "2 ч назад")
check("сутки", Format.ago(seconds: 200_000), "2 дн назад")
check("граница минуты", Format.ago(seconds: 59), "59 с назад")

print("\n== Имена файлов резервных копий ==")
check("владелец снимка",
      Backups.host(of: URL(fileURLWithPath: "/b/192.168.1.1_2026-08-27_10-00-00_running-config.txt")),
      "192.168.1.1")
check("адрес с подчёркиванием",
      Backups.host(of: URL(fileURLWithPath: "/b/my_router.local_2026-08-27_10-00-00_running-config.txt")),
      "my_router.local")
check("соседний адрес не путается",
      Backups.host(of: URL(fileURLWithPath: "/b/192.168.1.10_2026-08-27_10-00-00_running-config.txt")),
      "192.168.1.10")
check("посторонний файл — не наш",
      Backups.host(of: URL(fileURLWithPath: "/b/README.txt")), "")
check("адрес приводится к безопасному виду",
      Backups.safeHost("router.example.com:8080"), "router.example.com_8080")

print("\n== Статические маршруты ==")
let routes = StaticRouteParser.parse(config: sampleConfig)
check("нашли 4 маршрута", String(routes.count), "4")
check("маска → cidr", routes[0].destination, "10.50.0.0/16")
check("комментарий", routes[0].comment, "корпоративка")
check("флаг auto", routes[0].auto)
check("метрика не теряется при разборе", String(routes[0].metric ?? -1), "10")
check("default", routes[1].destination, "default")
check("ipv6", routes[2].destination, "2001:db8::/32")
check("reject", routes[3].reject)
check("команда собирается обратно",
      routes[0].command, "ip route 10.50.0.0 255.255.0.0 Wireguard0 metric 10 auto !корпоративка")
check("удаление берёт исходную строку",
      routes[3].deleteCommand, "no ip route 203.0.113.77 ISP reject")
do {
    try StaticRoute.validate(family: .ipv4, destination: "10.0.0.0/8", via: "ISP extra")
    check("интерфейс с лишним токеном должен быть отклонён", false)
} catch {
    check("интерфейс с лишним токеном не попадёт в CLI", true)
}
do {
    try StaticRoute.validate(family: .ipv4, destination: "10.0.0.0/8", via: "ISP",
                             comment: "обычный\nкомментарий")
    check("многострочный комментарий должен быть отклонён", false)
} catch {
    check("многострочный комментарий не попадёт в CLI", true)
}

print("\n== Импорт из BAT ==")
let bat = """
@echo off
chcp 65001 > nul
rem Маршруты
route -p add 100.64.0.0 mask 255.192.0.0 192.168.1.1
route add 8.8.8.8 mask 255.255.255.255 192.168.1.1 metric 1
ip route 172.16.0.0 255.240.0.0 Wireguard0 auto
что-то непонятное
pause
"""
let imported = StaticRouteParser.parseImport(bat)
check("распознано 3", String(imported.routes.count), "3")
check("пропущена 1 строка", String(imported.skipped.count), "1")
check("cidr из маски", imported.routes[0].destination, "100.64.0.0/10")
check("хост /32 без префикса", imported.routes[1].destination, "8.8.8.8")
check("метрика Windows сохраняется", String(imported.routes[1].metric ?? -1), "1")
check("keenetic-строка", imported.routes[2].command, "ip route 172.16.0.0 255.240.0.0 Wireguard0 auto")

print("\n== Экспорт в BAT ==")
// «routes» разобраны выше из sampleConfig: ipv4+auto, default, ipv6 и reject.
let unsupported = StaticRouteParser.batUnsupported(routes)
check("непереносимое посчитано", String(unsupported.count), "3")
let batOut = StaticRouteParser.exportBAT(routes)
check("переносимый маршрут выгружен",
      batOut.contains("route -p add 10.50.0.0 mask 255.255.0.0 Wireguard0"))
check("ipv6 не выброшен, а помечен", batOut.contains("rem не переносится в Windows: ipv6 route"))
check("default помечен", batOut.contains("rem не переносится в Windows: ip route default"))
check("reject помечен", batOut.contains("rem не переносится в Windows: ip route 203.0.113.77 ISP reject"))
check("ни одна строка не потерялась",
      String(batOut.split(separator: "\r\n").filter {
          $0.hasPrefix("route -p add") || $0.hasPrefix("rem не переносится")
      }.count), "4")

let duplicated = StaticRouteParser.parse(config: """
ip route 10.0.0.0 255.0.0.0 Wireguard0 auto
ip route 10.0.0.0 255.0.0.0 Wireguard0 auto
""")
check("повтор в конфигурации не даёт двойного id", String(duplicated.count), "1")

print("\n== WireGuard ==")
let wgText = """
[Interface]
PrivateKey = uEjNGm+privatekeyexamplevaluegoeshere1234567=
Address = 10.7.0.2/24, fd00::2/64
ListenPort = 51820
MTU = 1420
Jc = 4
Jmin = 40
Jmax = 70
S1 = 15
S2 = 60
H1 = 1234567
H2 = 2345678
H3 = 3456789
H4 = 4567890

[Peer]
PublicKey = pUbLiCkEy1234567890abcdefghijklmnopqrstuv=
PresharedKey = pReShArEd1234567890abcdefghijklmnopqrstu=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.9:51820
PersistentKeepalive = 25
"""
let wg = try WireGuardConfig.parse(text: wgText, fileName: "test.conf")
check("тип определён", wg.flavour, "AmneziaWG")
check("приватный ключ", wg.privateKey.hasPrefix("uEjNGm+"))
check("публичный ключ пира", wg.publicKey, "pUbLiCkEy1234567890abcdefghijklmnopqrstuv=")
let stages = try WireGuardPlanner.stages(interface: "Wireguard0", config: wg)
let wgCommands = stages.flatMap(\.commands)
check("первая команда — down", wgCommands.first ?? "nil", "interface Wireguard0 down")
check("пир создаётся до AllowedIPs",
      wgCommands.firstIndex(where: { $0.hasSuffix("wireguard peer \"pUbLiCkEy1234567890abcdefghijklmnopqrstuv=\"") })!
      < wgCommands.firstIndex(where: { $0.contains("allow-ips 0.0.0.0 0.0.0.0") })!)
check("приватный ключ после подготовки",
      wgCommands.firstIndex(where: { $0.contains("private-key") })!
      > wgCommands.firstIndex(where: { $0.contains("endpoint") })!)
check("ipv4 адрес интерфейса",
      wgCommands.contains("interface Wireguard0 ip address 10.7.0.0 255.255.255.0"))
check("ipv6 адрес интерфейса",
      wgCommands.contains("interface Wireguard0 ipv6 address fd00::2/64"))
check("ASC для amnezia",
      wgCommands.contains("interface Wireguard0 wireguard asc 4 40 70 15 60 1234567 2345678 3456789 4567890"))
check("AllowedIPs чистятся перед записью",
      wgCommands.firstIndex(where: { $0.hasSuffix("no allow-ips") })!
      < wgCommands.firstIndex(where: { $0.contains("allow-ips ::") })!)
check("connect в конце", wgCommands.last?.hasSuffix("connect") ?? false)

let plainWG = try WireGuardConfig.parse(text: wgText.replacingOccurrences(of: "Jc = 4", with: ""), fileName: "x")
check("без Jc всё ещё amnezia (есть Jmin)", plainWG.isAmnezia)
do {
    var unsafe = wg
    unsafe.peers[0]["endpoint"] = "203.0.113.9:51820;interface Wireguard0 down"
    _ = try WireGuardPlanner.stages(interface: "Wireguard0", config: unsafe)
    check("служебный символ в endpoint должен быть отклонён", false)
} catch {
    check("служебный символ в endpoint не попадёт в CLI", true)
}
do {
    var unsafe = wg
    unsafe.interfaceValues["h1"] = "123;interface Wireguard0 down"
    _ = try WireGuardPlanner.stages(interface: "Wireguard0", config: unsafe)
    check("служебный символ в ASC должен быть отклонён", false)
} catch {
    check("служебный символ в ASC не попадёт в CLI", true)
}
do {
    var unsafe = wg
    unsafe.interfaceValues["i1"] = "GET / HTTP/1.1"
    unsafe.interfaceValues["s3"] = "1;interface Wireguard0 down"
    _ = try WireGuardPlanner.stages(interface: "Wireguard0", config: unsafe)
    check("служебный символ в S3 не попадёт в CLI", false)
} catch {
    check("служебный символ в S3 не попадёт в CLI", true)
}
do {
    var unsafe = wg
    unsafe.peers[0]["allowedips"] = "2001:db8::/129"
    _ = try WireGuardPlanner.stages(interface: "Wireguard0", config: unsafe)
    check("IPv6-префикс вне диапазона не попадёт в CLI", false)
} catch {
    check("IPv6-префикс вне диапазона не попадёт в CLI", true)
}
do {
    _ = try WireGuardConfig.parse(text: wgText + """

[Peer]
PublicKey = secondPeerExample1234567890abcdefghijklmnop=
AllowedIPs = 10.0.0.0/8
""", fileName: "two-peers.conf")
    check("несколько пиров должны быть отклонены", false)
} catch {
    check("несколько пиров не приводят к частичному обновлению", true)
}
do {
    _ = try WireGuardConfig.parse(
        text: wgText.replacingOccurrences(of: "AllowedIPs = 0.0.0.0/0, ::/0", with: ""),
        fileName: "no-routes.conf")
    check("конфиг без AllowedIPs должен быть отклонён", false)
} catch {
    check("конфиг без AllowedIPs не выключит маршруты", true)
}

let live = WireGuardState.parse(config: sampleConfig, interface: "Wireguard0")
check("пир прочитан", live.peerKeys == ["aBcDeFgH1234567890abcdefghijklmnopqrstuv="])
check("порт прочитан", live.listenPort, "51820")
check("интерфейс поднят", live.isUp)
check("MTU интерфейса прочитан", String(live.mtu ?? -1), "1420")
check("список wg-интерфейсов", WireGuardState.interfaceNames(config: sampleConfig) == ["Wireguard0"])
let wireGuardServerConfig = sampleConfig + """

interface Wireguard3
    description Wireguard VPN Server
    security-level private
    wireguard peer serverClientKey=
        endpoint 198.51.100.7:51820
        allow-ips 10.99.0.2 255.255.255.255
        !
    ip address 10.99.0.1 255.255.255.0
    up
!
"""
check("VPN-сервер не считается клиентским туннелем",
      WireGuardState.interfaceNames(config: wireGuardServerConfig) == ["Wireguard0"])
check("полный разбор всё ещё видит сервер для диагностики",
      WireGuardState.allInterfaceNames(config: wireGuardServerConfig) == ["Wireguard0", "Wireguard3"])
let renamePlan = try? WireGuardPlanner.planRename(interface: "Wireguard0",
                                                  current: "старое имя",
                                                  desired: "Hetzner FIN")
check("имя WireGuard меняется через description",
      renamePlan?.commands.first ?? "nil",
      "interface Wireguard0 description \"Hetzner FIN\"")
let clearNamePlan = try? WireGuardPlanner.planRename(interface: "Wireguard0",
                                                    current: "старое имя",
                                                    desired: "   ")
check("пустое имя WireGuard снимает description",
      clearNamePlan?.commands.first ?? "nil",
      "interface Wireguard0 no description")
check("имя WireGuard с переводом строки отклоняется",
      (try? WireGuardPlanner.planRename(interface: "Wireguard0",
                                        current: "старое имя",
                                        desired: "bad\nname")) == nil)

print("\n== Планировщик импорта ==")
let spec = SourceCatalog.spec(for: "kinopub")!
let data = SourceData(spec: spec,
                      entries: ["kinopub.tv", "api.kinopub.me", "new1.example.com", "new2.example.com"],
                      fromCache: false, fetchedAt: Date(), skipped: [], duplicates: 0,
                      subnetsV4: [], subnetsV6: [])
var reserved = Set(groups.keys)
let plan = Planner.planImport(groups: groups, data: data, chunkSize: 3,
                              removeStale: true, reservedIDs: &reserved)
check("stale 5.61.239.10 удаляется",
      plan.commands.contains("no object-group fqdn domain-list0 include 5.61.239.10"))
check("добавляются только новые", String(plan.addCount), "2")
check("создан новый список при переполнении", String(plan.createdGroups.count), "1")
check("новый id не пересекается", plan.createdGroups.first?.ident ?? "nil", "domain-list2")
check("удаления идут первыми в merge",
      Planner.merge(title: "t", plans: [plan]).commands.first?.hasPrefix("no ") ?? false)
check("маршруты не трогаются",
      !plan.commands.contains(where: { $0.contains("dns-proxy") }))

let firstRouter = UUID()
let secondRouter = UUID()
let boundPlan = plan.forRouter(firstRouter)
var firstProfile = RouterProfile()
firstProfile.id = firstRouter
firstProfile.host = "192.168.1.1"
check("привязка плана не меняет его идентификатор", boundPlan.id == plan.id)
check("план помнит роутер", boundPlan.routerID == firstRouter)
let profileBoundPlan = plan.forRouter(firstProfile)
check("план помнит ключ подключения", profileBoundPlan.routerConnectionKey == firstProfile.connectionKey)
var webProfile = RouterProfile()
webProfile.transport = .http
webProfile.webURL = "https://admin:secret@example.com/rci?token=leak"
check("credentials в webURL распознаются", webProfile.hasEmbeddedWebCredentials)
check("effective URL не содержит credentials", webProfile.effectiveWebURL, "https://example.com/")
webProfile.removeEmbeddedWebCredentials()
check("credentials удаляются из профиля", !webProfile.hasEmbeddedWebCredentials)
check("merge сохраняет общего владельца",
      Planner.merge(title: "t", plans: [boundPlan]).routerID == firstRouter)
check("merge разных роутеров не выбирает владельца",
      Planner.merge(title: "t", plans: [boundPlan, plan.forRouter(secondRouter)]).routerID == nil)
var syncReserved: Set<String> = []
let syncReference = [
    "one": FqdnGroup(ident: "one", descriptionText: "первый", includes: ["repeat.example"]),
    "two": FqdnGroup(ident: "two", descriptionText: "второй", includes: ["repeat.example"]),
]
let syncPlan = Planner.planSync(reference: syncReference, current: [:], chunkSize: 300,
                                reservedIDs: &syncReserved)
check("перенос не добавляет один домен дважды", syncPlan.addCount == 1)

print("\n== Планировщик маршрутов ==")
let routePlan = Planner.planRoutes(groups: Array(groups.values), interface: "ISP", auto: true, reject: false)
check("2 команды маршрутов", String(routePlan.commands.count), "2")
check("формат команды", routePlan.commands.allSatisfy { $0.hasSuffix(" ISP auto") })
let skipPlan = Planner.planRoutes(groups: Array(groups.values), interface: "Wireguard0", auto: true, reject: false)
check("уже назначенное пропускается", skipPlan.isEmpty)
let failoverPlan = Planner.planRoutes(groups: Array(groups.values),
                                     interfaces: ["Wireguard0", "ISP"], auto: true, reject: false)
let failoverAdds = failoverPlan.commands.filter { $0.hasPrefix("dns-proxy route object-group ") }
check("резервирование назначает каждый список на оба интерфейса",
      failoverPlan.routeTargets.count == 4 && failoverAdds.count == 4)
let primaryIndexes = failoverAdds.indices.filter { failoverAdds[$0].contains(" Wireguard0 auto") }
check("резервирование сохраняет порядок интерфейсов",
      primaryIndexes.count == 2
      && primaryIndexes.allSatisfy { $0 + 1 < failoverAdds.count
          && failoverAdds[$0 + 1].contains(" ISP auto") })
check("старые маршруты перед резервированием снимаются",
      failoverPlan.commands.first?.hasPrefix("no dns-proxy route object-group ") ?? false)
check("план запоминает точную failover-цепочку",
      failoverPlan.exactRouteChains.values.allSatisfy {
          $0 == [
              DnsRouteAssignment(interface: "Wireguard0", auto: true, reject: false),
              DnsRouteAssignment(interface: "ISP", auto: true, reject: false),
          ]
      })

// Повторное назначение той же цепочки не должно ничего делать: план
// сначала снимает маршруты и только потом вешает заново, и в этот
// промежуток домены уходят мимо туннеля.
var alreadyChained: [String: FqdnGroup] = [:]
for (ident, group) in groups {
    var copy = group
    copy.routeLines = [
        "dns-proxy route object-group \(ident) Wireguard0 auto",
        "dns-proxy route object-group \(ident) ISP auto",
    ]
    alreadyChained[ident] = copy
}
let repeatPlan = Planner.planRoutes(groups: Array(alreadyChained.values),
                                    interfaces: ["Wireguard0", "ISP"],
                                    auto: true, reject: false)
check("та же цепочка второй раз — план пустой", repeatPlan.isEmpty)
check("и маршруты не снимаются впустую",
      !repeatPlan.commands.contains { $0.hasPrefix("no dns-proxy route") })

let reorderPlan = Planner.planRoutes(groups: Array(alreadyChained.values),
                                     interfaces: ["ISP", "Wireguard0"],
                                     auto: true, reject: false)
check("другой порядок — план не пустой", !reorderPlan.isEmpty)
let flagPlan = Planner.planRoutes(groups: Array(alreadyChained.values),
                                  interfaces: ["Wireguard0", "ISP"],
                                  auto: false, reject: false)
check("другие флаги — тоже перекладываем", !flagPlan.isEmpty)

var partialChain = alreadyChained
if let first = partialChain.keys.sorted().first {
    partialChain[first]?.routeLines = ["dns-proxy route object-group \(first) Wireguard0 auto"]
}
let mixedPlan = Planner.planRoutes(groups: Array(partialChain.values),
                                   interfaces: ["Wireguard0", "ISP"],
                                   auto: true, reject: false)
check("трогаем только тот список, где цепочка не совпала",
      mixedPlan.commands.filter { $0.hasPrefix("no dns-proxy route") }.count == 1)

var exactFailoverGroups = groups
for ident in Array(exactFailoverGroups.keys) {
    exactFailoverGroups[ident]?.routeLines = [
        "dns-proxy route object-group \(ident) Wireguard0 auto",
        "dns-proxy route object-group \(ident) ISP auto",
    ]
}
check("проверка принимает точный порядок и флаги",
      PlanVerifier.problems(plan: failoverPlan, groups: exactFailoverGroups, limit: 300).isEmpty)

var reversedFailoverGroups = exactFailoverGroups
if let ident = reversedFailoverGroups.keys.sorted().first {
    reversedFailoverGroups[ident]?.routeLines.reverse()
}
check("проверка замечает переставленный failover",
      PlanVerifier.problems(plan: failoverPlan, groups: reversedFailoverGroups, limit: 300)
        .contains { $0.contains("цепочка маршрутов не совпала") })

var wrongFlagsGroups = exactFailoverGroups
if let ident = wrongFlagsGroups.keys.sorted().first {
    wrongFlagsGroups[ident]?.routeLines[0] =
        "dns-proxy route object-group \(ident) Wireguard0 reject"
}
check("проверка замечает неверные auto/reject",
      PlanVerifier.problems(plan: failoverPlan, groups: wrongFlagsGroups, limit: 300)
        .contains { $0.contains("цепочка маршрутов не совпала") })

var extraRouteGroups = exactFailoverGroups
if let ident = extraRouteGroups.keys.sorted().first {
    extraRouteGroups[ident]?.routeLines.append(
        "dns-proxy route object-group \(ident) Wireguard9 auto")
}
check("проверка замечает лишний маршрут в цепочке",
      PlanVerifier.problems(plan: failoverPlan, groups: extraRouteGroups, limit: 300)
        .contains { $0.contains("цепочка маршрутов не совпала") })

let strictSinglePlan = Planner.planRoutes(
    groups: [FqdnGroup(ident: "single")], interface: "ISP", auto: true, reject: false)
let strictSingleActual = [
    "single": FqdnGroup(
        ident: "single",
        routeLines: ["dns-proxy route object-group single ISP reject"]),
]
check("обычное назначение тоже проверяет флаги",
      PlanVerifier.problems(plan: strictSinglePlan, groups: strictSingleActual, limit: 300)
        .contains { $0.contains("с другими флагами") })
let flagRepairPlan = Planner.planRoutes(
    groups: [strictSingleActual["single"]!], interface: "ISP", auto: true, reject: false)
check("неверные флаги не считаются уже назначенным маршрутом",
      flagRepairPlan.commands == [
          "no dns-proxy route object-group single ISP reject",
          "dns-proxy route object-group single ISP auto",
      ])

let manualPlan = try? ManualFqdnPlanner.plan(ident: "test", description: "test",
                                             entriesText: "2ip.io\nwhoer.net")
check("ручной список test создаётся", manualPlan?.createdGroups.first?.ident ?? "", "test")
check("ручной список содержит два домена", String(manualPlan?.addCount ?? 0), "2")
check("опасное имя ручного списка отбивается",
      (try? ManualFqdnPlanner.plan(ident: "test;rm", description: "test", entriesText: "a.com")) == nil)
check("битая строка ручного списка не пропускается",
      (try? ManualFqdnPlanner.plan(ident: "test2", description: "test2", entriesText: "not-a-domain")) == nil)

print("\n== Детектор ошибок CLI ==")
check("error[code]", CLI.failed("Command::Base error[7405600]: no such interface"))
check("unknown command", CLI.failed("unknown command"))
check("домен со словом error не ложное срабатывание",
      !CLI.failed("object-group fqdn domain-list0 include error-tracker.example.com"))
check("пустой вывод чистый", !CLI.failed(""))
check("кавычки CLI", CLI.quote("itdog ru inside 2"), "\"itdog ru inside 2\"")
check("раскавычивание", CLI.unquote("\"itdog ru inside 2\""), "itdog ru inside 2")
check("ANSI вычищается", CLI.stripNoise("\u{1B}[32mok\u{1B}[0m\r\n"), "ok\n")
check("секрет WireGuard не попадает в журнал",
      CLI.redactSecrets("interface Wireguard0 wireguard private-key \"super-secret\""),
      "interface Wireguard0 wireguard private-key •••")
check("preshared-key без кавычек тоже скрывается",
      CLI.redactSecrets("wireguard peer key preshared-key another-secret"),
      "wireguard peer key preshared-key •••")

print("\n== SSH-транспорт: обработка недоступного хоста ==")
var probe = RouterProfile()
probe.host = "127.0.0.1"
probe.port = 47_999            // заведомо закрытый порт
probe.user = "admin"
let started = Date()
do {
    let transport = SSHTransport(profile: probe, password: "x")
    try transport.connect()
    check("должны были получить ошибку", false)
} catch let error as TransportError {
    let elapsed = Date().timeIntervalSince(started)
    print("       сообщение: \(error.message)")
    check("ошибка вернулась, а не зависание (\(String(format: "%.1f", elapsed)) с)", elapsed < 30)
    check("сообщение осмысленное", !error.message.isEmpty)
} catch {
    check("неожиданный тип ошибки", false)
}

print("\n== Конфигурация с CRLF (как отдаёт RCI) ==")
let crlfConfig = sampleConfig.replacingOccurrences(of: "\n", with: "\r\n")
check("сырой CRLF не разбирается (это и была ошибка)",
      RouterConfigParser.parseFqdnGroups(crlfConfig).count == 0)

let normalized = CLI.normalizeNewlines(crlfConfig)
check("после нормализации переводов строк — списки на месте",
      String(RouterConfigParser.parseFqdnGroups(normalized).count), "2")
check("маршруты тоже", String(StaticRouteParser.parse(config: normalized).count), "4")
check("интерфейсы тоже", String(RouterConfigParser.parseConfigInterfaces(normalized).count), "2")
check("wireguard тоже",
      WireGuardState.parse(config: normalized, interface: "Wireguard0").peerKeys.count == 1)
check("чистый LF не портится", CLI.normalizeNewlines(sampleConfig) == sampleConfig)
check("одиночный CR тоже режется",
      CLI.normalizeNewlines("a\rb").split(separator: "\n").count == 2)
check("ответ RCI распознаётся как конфигурация",
      RCITransport.looksLikeConfig(normalized))
check("HTML веб-панели отбивается",
      !RCITransport.looksLikeConfig(String(repeating: "<html><body>nope</body></html>", count: 20)))
do {
    let closedRCI = try RCITransport(
        profile: RouterProfile(name: "closed", host: "127.0.0.1", port: 80,
                               user: "admin", webURL: "http://127.0.0.1/",
                               transport: .http),
        password: nil)
    closedRCI.close()
    do {
        try closedRCI.connect()
        check("закрытая RCI-сессия не используется повторно", false)
    } catch {
        check("закрытая RCI-сессия не используется повторно", true)
    }
} catch {
    check("тестовая RCI-сессия создаётся", false)
}

print("\n== Ping-Check ==")
let activePingText = """
sending ICMP ECHO request to 1.1.1.1...
PING 1.1.1.1 (1.1.1.1) from nwg0: 56 (84) bytes of data.
64 bytes from 1.1.1.1: icmp_req=1, ttl=57, time=12.35 ms.
64 bytes from 1.1.1.1: icmp_req=2, ttl=57, time=10,25 ms.
64 bytes from 1.1.1.1: icmp_req=3, ttl=57, time<1 ms.
--- 1.1.1.1 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss,
0 duplicate(s), time 3001.40 ms.
"""
let activePing = InterfacePingProbe.parse(activePingText,
                                          interface: "Wireguard0", target: "1.1.1.1")
check("активный ping извлекает три RTT", String(activePing.rtt.count), "3")
check("активный ping понимает десятичную запятую",
      String(format: "%.2f", activePing.rtt[1]), "10.25")
check("активный ping извлекает системный интерфейс", activePing.source ?? "nil", "nwg0")
check("активный ping считает нулевые потери",
      String(format: "%.0f", activePing.lossPercent), "0")
check("команда ping закреплена за интерфейсом",
      (try? InterfacePingProbe.command(interface: "Wireguard0", target: "1.1.1.1", count: 3)) ?? "nil",
      "tools ping 1.1.1.1 count 3 source-interface Wireguard0")
check("IPv6 использует ping6",
      (try? InterfacePingProbe.command(interface: "Wireguard0", target: "2606:4700:4700::1111", count: 2)) ?? "nil",
      "tools ping6 2606:4700:4700::1111 count 2 source-interface Wireguard0")
check("CLI-инъекция в цели ping отбивается",
      (try? InterfacePingProbe.command(interface: "Wireguard0", target: "1.1.1.1; reboot")) == nil)
check("TCP-проверка привязана к адресу туннеля",
      (try? InterfacePingProbe.command(interface: "Wireguard3", target: "1.1.1.1",
                                       method: .tcp, port: 443,
                                       sourceAddress: "172.16.6.2 255.255.255.255")) ?? "nil",
      "tools iperf3 1.1.1.1 ipv4 tcp port 443 time 1 source-address 172.16.6.2")
check("TCP без адреса туннеля не запускается",
      (try? InterfacePingProbe.command(interface: "Wireguard3", target: "1.1.1.1",
                                       method: .tcp, port: 443)) == nil)
let tcpConnect = InterfacePingProbe.parse("""
starting iperf3 client to server whoer.net...
iperf3: error - received an unknown control message (ensure other side is iperf3 and not iperf)
""", interface: "Wireguard3", target: "whoer.net",
    method: .tcp, port: 443, sourceAddress: "172.16.6.2")
check("TCP-соединение с чужим протоколом считается доступным", tcpConnect.isReachable)
check("успешный TCP-connect не показывает ошибку", tcpConnect.error == nil)
check("успешный TCP-connect считает один ответ", String(tcpConnect.received), "1")
let measuredTCP = InterfacePingProbe.parse("""
iperf3: error - received an unknown control message (ensure other side is iperf3 and not iperf)
""", interface: "Wireguard3", target: "whoer.net",
    method: .tcp, port: 443, sourceAddress: "172.16.6.2",
    elapsedMilliseconds: 42.5)
check("TCP-connect показывает измеренную задержку",
      String(format: "%.1f", measuredTCP.latestRTT ?? -1), "42.5")
let blockedTCP = InterfacePingProbe.parse("""
iperf3: error - unable to connect to server: Host is unreachable
""", interface: "Wireguard3", target: "1.1.1.1",
    method: .tcp, port: 443, sourceAddress: "172.16.6.2")
check("TCP без ответа конечного узла показывает ошибку", blockedTCP.error != nil)
let udpTrace = InterfacePingProbe.parse("""
starting traceroute to one.one.one.one...
traceroute to one.one.one.one (1.1.1.1), 16 hops maximum, 52 byte packets.
 1  172.16.6.1 (172.16.6.1)  53.101 ms
 2  one.one.one.one (1.1.1.1)  58.420 ms
""", interface: "Wireguard3", target: "one.one.one.one",
    method: .udp, port: 53, sourceAddress: "172.16.6.2")
check("UDP-трассировка берёт RTT конечного узла",
      String(format: "%.2f", udpTrace.latestRTT ?? -1), "58.42")
check("UDP-трассировка не считает промежуточный хоп",
      String(udpTrace.rtt.count), "1")
let lostPing = InterfacePingProbe.parse("""
PING 1.1.1.1 (1.1.1.1) from nwg1: 56 (84) bytes of data.
3 packets transmitted, 0 packets received, 100% packet loss,
""", interface: "Wireguard1", target: "1.1.1.1")
check("100% потерь распознаются без ложной ошибки", lostPing.error == nil)
check("недоступный интерфейс имеет 100% потерь",
      String(format: "%.0f", lostPing.lossPercent), "100")

// Фрагмент настоящей конфигурации роутера.
let pingConfig = """
ping-check profile vpn\r
    host google.com\r
    update-interval 3\r
    mode icmp\r
    min-success 3\r
    max-fails 3\r
!\r
interface GigabitEthernet1\r
    description dom.ru\r
    ping-check profile default\r
!\r
interface Wireguard0\r
    description Dataforest\r
    ping-check profile vpn\r
    ping-check restart\r
!\r
"""
let ping = PingCheckParser.parse(config: CLI.normalizeNewlines(pingConfig))
check("профилей найдено", String(ping.profiles.count), "2")
let vpn = ping.profiles.first { $0.name == "vpn" }
check("узел проверки", vpn?.host ?? "nil", "google.com")
check("интервал", String(vpn?.updateInterval ?? -1), "3")
check("порог отказа", String(vpn?.maxFails ?? -1), "3")
check("порог подъёма", String(vpn?.minSuccess ?? -1), "3")
check("режим", vpn?.mode.rawValue ?? "nil", "icmp")
check("default распознан как встроенный",
      ping.profiles.first { $0.name == "default" }?.isBuiltIn ?? false)
check("привязка к Wireguard0", ping.bindings["Wireguard0"]?.profile ?? "nil", "vpn")
check("перезапуск включён", ping.bindings["Wireguard0"]?.restart ?? false)
check("у GigabitEthernet1 перезапуска нет", !(ping.bindings["GigabitEthernet1"]?.restart ?? true))
check("профиль без изменений не предлагает сохранять",
      PingCheckParser.planSave(vpn!, existing: vpn!).isEmpty)
var changedVPN = vpn!
changedVPN.timeout = 2
check("настоящее изменение по-прежнему создаёт команды",
      !PingCheckParser.planSave(changedVPN, existing: vpn!).isEmpty)
check("mode и update-interval никогда не снимаются — у них нет формы no",
      !PingCheckParser.planSave(PingCheckProfile(name: "t", host: "a.b"), existing: vpn!)
          .commands.contains { $0.contains("no mode") || $0.contains("no update-interval") })
check("очистка порога даёт форму «no»",
      PingCheckParser.planSave(PingCheckProfile(name: "vpn", host: "google.com", mode: .icmp,
                                                updateInterval: 3), existing: vpn!)
          .commands.contains("ping-check profile vpn no max-fails"))
check("режим TCP требует порт",
      { do { try PingCheckProfile.validate(
                 PingCheckProfile(name: "t", host: "a.b", mode: .connect)); return false }
        catch { return true } }())
check("порог вне диапазона 1…10 отбивается",
      { do { try PingCheckProfile.validate(
                 PingCheckProfile(name: "t", host: "a.b", maxFails: 50)); return false }
        catch { return true } }())
check("интервал меньше 3 отбивается",
      { do { try PingCheckProfile.validate(
                 PingCheckProfile(name: "t", host: "a.b", updateInterval: 1)); return false }
        catch { return true } }())
check("режим URI требует схему",
      { do { try PingCheckProfile.validate(
                 PingCheckProfile(name: "t", uri: "example.com", mode: .uri)); return false }
        catch { return true } }())
check("узел с переводом строки не превращается в команду",
      { do { try PingCheckProfile.validate(
                 PingCheckProfile(name: "t", host: "1.1.1.1\nsystem configuration save")); return false }
        catch { return true } }())
check("URI со встроенным паролем не принимается",
      { do { try PingCheckProfile.validate(
                 PingCheckProfile(name: "t", uri: "https://user:pass@example.com", mode: .uri)); return false }
        catch { return true } }())
check("режимы ровно те, что в справочнике",
      PingCheckProfile.Mode.allCases.map(\.rawValue).joined(separator: ","),
      "icmp,connect,tls,uri")
check("снятие профиля с интерфейса",
      PingCheckParser.planAssign(interface: "Wireguard0", profile: nil, restart: false,
                                 current: ping.bindings["Wireguard0"]).commands.joined(separator: " | "),
      "interface Wireguard0 no ping-check profile | interface Wireguard0 no ping-check restart")
check("удаление снимает профиль с интерфейсов первым",
      PingCheckParser.planDelete(vpn!, usedBy: ["Wireguard0"]).commands.first ?? "nil",
      "interface Wireguard0 no ping-check profile")
check("без изменений план пустой",
      PingCheckParser.planAssign(interface: "Wireguard0", profile: "vpn", restart: true,
                                 current: ping.bindings["Wireguard0"]).isEmpty)

print("\n== Криптография схемы x-ndw4 ==")
check("SHA3-512 пустой строки (FIPS 202)", SHA3.hash512("").hexString,
  "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26")
check("SHA3-512(abc)", SHA3.hash512("abc").hexString,
  "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0")
check("HMAC-SHA3-512 (RFC 4231 #1)",
  SHA3.hmac512(key: [UInt8](repeating: 0x0b, count: 20), message: "Hi There").hexString,
  "eb3fbd4b2eaab8f5c504bd3a41465aacec15770a7cabac531e482f860b5ec7ba47ccb2c6f2afce8f88d22b6dc61380f23a668fd3888bb80537c0a0b86407689e")
check("HMAC-SHA3-512, ключ длиннее блока",
  SHA3.hmac512(key: [UInt8](repeating: 0xaa, count: 131),
               message: "Test Using Larger Than Block-Size Key - Hash Key First").hexString,
  "00f751a9e50695b090ed6911a4b65524951cdc15a73a5d58bb55215ea2cd839ac79d2b44a39bafab27e83fde9e11f6340b11d991b1b91bf2eee7fc872426c3a4")
check("BLAKE2b-512(abc) (RFC 7693)", Blake2b.hash(Array("abc".utf8), length: 64).hexString,
  "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
check("BLAKE2b-512, ровно один блок", Blake2b.hash([UInt8](repeating: 0, count: 128), length: 64).hexString,
  "865939e120e6805438478841afb739ae4250cf372653078a065cdcfffca4caf798e6d462b65d658fc165782640eded70963449ae1500fb0f24981d7727e22c41")
do {
    let tag = try Argon2.hash(
        password: [UInt8](repeating: 0x01, count: 32), salt: [UInt8](repeating: 0x02, count: 16),
        secret: [UInt8](repeating: 0x03, count: 8), associated: [UInt8](repeating: 0x04, count: 12),
        parameters: .init(iterations: 3, memoryKiB: 32, parallelism: 4, tagLength: 32))
    check("Argon2id, контрольный пример RFC 9106", tag.hexString,
          "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
} catch { failures += 1; checks += 1; print("  FAIL Argon2id: \(error)") }

print("\n== Защищённые резервные копии ==")
let backupKey = Data((0..<32).map(UInt8.init))
let backupText = "interface Wireguard0\n    wireguard private-key top-secret\n!\n"
do {
    let encrypted = try SecureBackup.seal(backupText, keyData: backupKey)
    check("контейнер помечен как зашифрованный", SecureBackup.isEncrypted(encrypted))
    check("секрет не лежит в контейнере открытым текстом",
          !String(decoding: encrypted, as: UTF8.self).contains("top-secret"))
    check("AES-GCM расшифровывает снимок",
          try SecureBackup.open(encrypted, keyData: backupKey), backupText)

    var damaged = encrypted
    damaged[damaged.index(before: damaged.endIndex)] ^= 0x01
    check("подмена контейнера обнаруживается",
          (try? SecureBackup.open(damaged, keyData: backupKey)) == nil)
    check("чужой ключ не открывает снимок",
          (try? SecureBackup.open(encrypted, keyData: Data(repeating: 9, count: 32))) == nil)
} catch {
    failures += 1; checks += 5
    print("  FAIL AES-GCM backup: \(error)")
}

print("\n== Настройки переживают обновление приложения ==")
// Файл настроек от прошлой версии не знает новых полей. Синтезированный
// декодер на этом спотыкается, а Store в таком случае берёт значения по
// умолчанию — то есть молча стирает всё, что человек настроил.
let oldSettings = #"{"chunkSize":123,"keepBackups":7,"lastRouterID":"ABC"}"#.data(using: .utf8)!
if let restored = try? JSONDecoder().decode(AppSettings.self, from: oldSettings) {
    check("старое значение сохранилось", String(restored.chunkSize), "123")
    check("и второе тоже", String(restored.keepBackups), "7")
    check("выбранный роутер не потерян", restored.lastRouterID, "ABC")
    check("новое поле взяло значение по умолчанию", !restored.autoUpdateEnabled)
    check("и число тоже", String(restored.autoUpdateHours), "24")
    check("и список", restored.autoUpdateSources.isEmpty)
    check("новый интервал проверки VPN взял безопасное значение",
          String(restored.wireGuardProbeIntervalSeconds), "3")
} else {
    check("файл настроек прошлой версии читается", false)
}
check("новый интервал перечитывания взял значение по умолчанию",
      String((try? JSONDecoder().decode(AppSettings.self, from: oldSettings))?.autoReloadSeconds ?? -1),
      "60")
check("пустой объект не ломает чтение",
      (try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))) != nil)
check("полный цикл записи и чтения",
      { var s = AppSettings(); s.autoUpdateEnabled = true; s.chunkSize = 55
        guard let data = try? JSONEncoder().encode(s),
              let back = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return false }
        return back.autoUpdateEnabled && back.chunkSize == 55 }())

print("\n== Возврат по резервной копии ==")
let snapshotConfig = """
interface Wireguard0
    description Dataforest
!
object-group fqdn domain-list0
    description "мой список"
    include one.example
    include two.example
!
object-group fqdn domain-list1
    description "второй"
    include three.example
!
dns-proxy route object-group domain-list0 Wireguard0 auto
ip route 10.50.0.0 255.255.0.0 Wireguard0 metric 10 auto
!
"""
let currentConfig = """
interface Wireguard0
    description Dataforest
!
object-group fqdn domain-list0
    description "мой список"
    include one.example
    include added.example
!
object-group fqdn domain-list2
    description "новый"
    include fresh.example
!
dns-proxy route object-group domain-list0 Wireguard0
ip route 172.16.0.0 255.240.0.0 Wireguard0 auto
!
"""
let diff = Restore.compare(backup: snapshotConfig, current: currentConfig)
check("расхождения найдены", !diff.isEmpty)
check("сверка сохраняет идентификатор при копировании", { () -> Bool in
    let copy = diff
    return copy.id == diff.id
}())
check("пропавший домен замечен", diff.missingDomains["domain-list0"] == ["two.example"])
check("лишний домен замечен", diff.extraDomains["domain-list0"] == ["added.example"])
check("исчезнувший список", diff.missingGroups.map(\.ident), ["domain-list1"])
check("появившийся список", diff.extraGroups.map(\.ident), ["domain-list2"])
check("маршрут списка изменился — старый вернуть",
      diff.missingRouteLines, ["dns-proxy route object-group domain-list0 Wireguard0 auto"])
check("а новый снять",
      diff.extraRouteLines, ["dns-proxy route object-group domain-list0 Wireguard0"])
check("статический маршрут вернуть", diff.missingRoutes.map(\.destination), ["10.50.0.0/16"])
check("статический маршрут снять", diff.extraRoutes.map(\.destination), ["172.16.0.0/12"])

let restorePlan = Restore.plan(diff, chunkSize: 300, title: "Возврат")
let restoreText = restorePlan.commands.joined(separator: "\n")
check("лишний домен удаляется",
      restoreText.contains("no object-group fqdn domain-list0 include added.example"))
check("пропавший домен возвращается",
      restoreText.contains("object-group fqdn domain-list0 include two.example"))
check("появившийся список удаляется целиком",
      restoreText.contains("no object-group fqdn domain-list2"))
check("исчезнувший список создаётся заново",
      restoreText.contains("object-group fqdn domain-list1 description \"второй\""))
check("и наполняется", restoreText.contains("object-group fqdn domain-list1 include three.example"))
check("статический маршрут возвращается",
      restoreText.contains("ip route 10.50.0.0 255.255.0.0 Wireguard0 metric 10 auto"))
check("лишний статический снимается",
      restoreText.contains("no ip route 172.16.0.0 255.240.0.0 Wireguard0 auto"))

// Порядок: список должен появиться раньше, чем на него вешают маршрут.
let createIndex = restorePlan.commands.firstIndex { $0 == "object-group fqdn domain-list1" } ?? .max
let routeIndex = restorePlan.commands.firstIndex {
    $0.hasPrefix("dns-proxy route object-group domain-list0")
} ?? -1
check("маршруты идут после создания списков", createIndex < routeIndex)
let dropIndex = restorePlan.commands.firstIndex { $0.hasPrefix("no dns-proxy route") } ?? .max
check("лишний маршрут снимается первым делом", dropIndex == 0)

check("одинаковые конфигурации — расхождений нет",
      Restore.compare(backup: snapshotConfig, current: snapshotConfig).isEmpty)
check("CRLF из RCI не мешает сверке",
      Restore.compare(backup: snapshotConfig.replacingOccurrences(of: "\n", with: "\r\n"),
                      current: snapshotConfig).isEmpty)

print("\n== Свои источники ==")
check("адреса из многострочного поля",
      CustomSource.addresses(from: " https://a/x \n\n https://b/y ,https://c/z ").joined(separator: "|"),
      "https://a/x|https://b/y|https://c/z")
check("подпись по хосту", CustomSource.subtitle(for: ["https://example.com/list.txt"]), "example.com")
check("подпись по имени файла", CustomSource.subtitle(for: ["/tmp/my.txt"]), "my.txt")
check("зеркала посчитаны",
      CustomSource.subtitle(for: ["https://a/x", "https://b/x"]), "a · зеркал: 1")

func sourceError(_ source: CustomSource) -> String? {
    do { try CustomSource.validate(source, existing: []); return nil }
    catch { return (error as? TransportError)?.message ?? error.localizedDescription }
}
check("без названия не сохраняется", sourceError(CustomSource()) != nil)
check("без префикса не сохраняется",
      sourceError(CustomSource(title: "Мой", urls: ["https://a/x"])) != nil)
check("без адреса не сохраняется",
      sourceError(CustomSource(title: "Мой", descriptionPrefix: "my")) != nil)
check("нормальный источник принимается",
      sourceError(CustomSource(title: "Мой", descriptionPrefix: "my list",
                               urls: ["https://a/x"])) == nil)
check("несуществующий файл отбивается",
      sourceError(CustomSource(title: "Мой", descriptionPrefix: "my",
                               urls: ["/нет/такого/файла.txt"])) != nil)
check("чужая схема отбивается",
      sourceError(CustomSource(title: "Мой", descriptionPrefix: "my",
                               urls: ["ftp://a/x"])) != nil)
check("старый источник не запускает чужую схему",
      (try? SourceLoader.fetch("ftp://a/x")) == nil)
check("префикс с переводом строки отбивается",
      sourceError(CustomSource(title: "Мой", descriptionPrefix: "my\nlist",
                               urls: ["https://a/x"])) != nil)
check("адрес источника с паролем отбивается",
      sourceError(CustomSource(title: "Мой", descriptionPrefix: "my",
                               urls: ["https://user:pass@example.com/x"])) != nil)
check("сетевой адрес без сервера отбивается",
      sourceError(CustomSource(title: "Мой", descriptionPrefix: "my",
                               urls: ["https:///x"])) != nil)
check("префикс встроенного источника занят",
      sourceError(CustomSource(title: "Мой", descriptionPrefix: "kinopub",
                               urls: ["https://a/x"])) != nil)

let mine = CustomSource(title: "Мой", descriptionPrefix: "my list", urls: ["https://a/x"])
check("ключ своего источника отличим", mine.spec.key.hasPrefix("custom-"))
check("свой кэш отдельным файлом", mine.spec.cacheName.hasPrefix("custom-"))
check("разные разделители в префиксе считаются одним владельцем",
      CustomSource.canonicalPrefix("My-list:_  2") == "my list 2")
check("префикс с дефисом не обходит защиту",
      sourceError(CustomSource(title: "Похожий", descriptionPrefix: "hoaxisr-ru-block",
                               urls: ["https://a/x"])) != nil)
check("старые конфликтующие источники распознаются",
      !CustomSource.conflictingSourceTitles([
        mine.spec,
        CustomSource(title: "Второй", descriptionPrefix: "my_list", urls: ["https://b/x"]).spec,
      ]).isEmpty)
check("путь к файлу не переписывается под github",
      SourceSpec.rawGitHub("/tmp/github.com/x.txt"), "/tmp/github.com/x.txt")

print("\n== Целостность источников подсетей ==")
// IPv4 и IPv6 — независимые обязательные части одного источника. Если одна
// часть не приехала, загрузчик не должен отдавать Planner неполную склейку:
// removeStale тогда удалил бы отсутствующие записи с роутера.
let subnetRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("keenetic-control-subnets-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: subnetRoot, withIntermediateDirectories: true)
let subnetDomain = subnetRoot.appendingPathComponent("domains.txt")
let subnetV4 = subnetRoot.appendingPathComponent("v4.txt")
let subnetV6 = subnetRoot.appendingPathComponent("v6.txt")
let subnetKey = "selftest-subnets-\(UUID().uuidString)"
let subnetCache = AppPaths.cache.appendingPathComponent("subnets-\(subnetKey).txt")
let domainCache = AppPaths.cache.appendingPathComponent("\(subnetKey).txt")
let partialSpec = SourceSpec(
    key: subnetKey, title: "Тест подсетей", subtitle: "selftest",
    descriptionPrefix: "selftest subnets", icon: "network",
    urls: [subnetDomain.path], cacheName: domainCache.lastPathComponent,
    subnetURLs: [subnetV4.path, subnetV6.path], minDomains: 1)
try? "example.com\n".write(to: subnetDomain, atomically: true, encoding: .utf8)
try? "1.1.1.0/24\n".write(to: subnetV4, atomically: true, encoding: .utf8)
try? "this-is-not-a-subnet\n".write(to: subnetV6, atomically: true, encoding: .utf8)
do {
    _ = try SourceLoader.load(partialSpec, ttlMinutes: 0, forceRefresh: true)
    check("частичная загрузка подсетей отклоняется", false)
} catch let error as TransportError {
    check("частичная загрузка подсетей отклоняется", true)
    check("ошибка объясняет, почему частичный список отброшен",
          (error.hint ?? "").contains("Частичный результат отброшен"))
} catch {
    check("частичная загрузка подсетей отклоняется", true)
}
try? "2001:db8::/32\n".write(to: subnetV6, atomically: true, encoding: .utf8)
let completeSubnets = try? SourceLoader.load(partialSpec, ttlMinutes: 0, forceRefresh: true)
check("полный набор подсетей загружается", completeSubnets?.subnetCount == 2)
try? "broken-again\n".write(to: subnetV6, atomically: true, encoding: .utf8)
let cachedSubnets = try? SourceLoader.load(partialSpec, ttlMinutes: 0, forceRefresh: true)
check("при следующей частичной загрузке берётся полный кэш",
      cachedSubnets?.fromCache == true && cachedSubnets?.subnetCount == 2)
try? FileManager.default.removeItem(at: subnetRoot)
try? FileManager.default.removeItem(at: subnetCache)
try? FileManager.default.removeItem(at: domainCache)

print("\n== Защита от лишних неудачных входов ==")
// Роутер объявляет x-ndw4, но на первой фазе не присылает соль. Пароль тут
// ни при чём: вторая попытка только потратит лимит роутера.
func ndw4Failure(_ reply: NDW4.Reply) -> NDW4.Failure? {
    do {
        try NDW4.authenticate(login: "admin", password: "x") { _ in reply }
        return nil
    } catch let failure as NDW4.Failure {
        return failure
    } catch {
        return nil
    }
}

let noSalt = ndw4Failure(NDW4.Reply(status: 401, data: nil))
check("первая фаза без соли распознана", noSalt?.handshakeUnsupported ?? false)
check("это не обвинение пароля", !(noSalt?.serverUntrusted ?? true))

let wrongStatus = ndw4Failure(NDW4.Reply(status: 200, data: nil))
check("неожиданный статус первой фазы — тоже несовместимость",
      wrongStatus?.handshakeUnsupported ?? false)

let badSalt = ndw4Failure(NDW4.Reply(
    status: 401, data: ["salt": "///",
                         "nonce": "server",
                         "iter": 3,
                         "memcost": 4096]))
check("нечитаемая соль — несовместимость", badSalt?.handshakeUnsupported ?? false)

let wildParameters = ndw4Failure(NDW4.Reply(
    status: 401,
    data: ["salt": Data(repeating: 7, count: 16).base64EncodedString(),
           "nonce": "server",
           "iter": 9999, "memcost": 4096]))
check("неправдоподобные параметры — несовместимость",
      wildParameters?.handshakeUnsupported ?? false)
let hugeMemory = ndw4Failure(NDW4.Reply(
    status: 401,
    data: ["salt": Data(repeating: 7, count: 16).base64EncodedString(),
           "nonce": "server",
           "iter": 3,
           "memcost": 65_537]))
check("слишком большая память отклоняется до Argon2",
      hugeMemory?.handshakeUnsupported ?? false)

do {
    let empty = try RCITransport.decodeJSONResponse(Data(), method: "GET", path: "rci/show/test")
    check("пустой JSON-ответ допустим", empty == nil)
} catch {
    check("пустой JSON-ответ допустим", false)
}
do {
    let object = try RCITransport.decodeJSONResponse(
        Data("{\"status\":\"ok\"}".utf8), method: "GET", path: "rci/show/test")
    check("корректный JSON-объект разбирается", (object as? [String: Any])?["status"] as? String == "ok")
} catch {
    check("корректный JSON-объект разбирается", false)
}
do {
    let fragment = try RCITransport.decodeJSONResponse(
        Data("true".utf8), method: "GET", path: "rci/show/test")
    check("JSON-фрагмент тоже разбирается", (fragment as? Bool) == true)
} catch {
    check("JSON-фрагмент тоже разбирается", false)
}
do {
    _ = try RCITransport.decodeJSONResponse(
        Data("<html><body>not json</body></html>".utf8), method: "GET", path: "rci/show/test")
    check("невалидный JSON не считается успешным ответом", false)
} catch let error as TransportError {
    check("невалидный JSON не считается успешным ответом",
          error.message.contains("не в формате JSON"))
} catch {
    check("невалидный JSON не считается успешным ответом", false)
}
do {
    _ = try RCITransport.decodeJSONResponse(
        Data("{\"password\":\"super-secret\"".utf8), method: "GET", path: "rci/show/test")
    check("секрет не проходит из битого JSON в ошибку", false)
} catch let error as TransportError {
    let rendered = error.message + "\n" + (error.hint ?? "")
    check("секрет не проходит из битого JSON в ошибку", !rendered.contains("super-secret"))
} catch {
    check("секрет не проходит из битого JSON в ошибку", false)
}

check("до отказа схему не пропускаем", !RCITransport.skipsModernAuth(host: "192.168.1.1"))
RCITransport.rememberModernAuthUnusable(host: "192.168.1.1")
check("после отказа пропускаем", RCITransport.skipsModernAuth(host: "192.168.1.1"))
check("и только для этого адреса", !RCITransport.skipsModernAuth(host: "192.168.1.2"))

check("разбор endpoint из WWW-Authenticate",
  RCITransport.endpoint(in: "x-ndw4-interactive endpoint=\"/auth\" data=\"e30=\"") ?? "nil", "auth")
check("endpoint отсутствует — не выдумываем",
  RCITransport.endpoint(in: "x-ndw2-interactive realm=\"X\"") == nil)
check("внешний endpoint не принимаем",
      RCITransport.endpoint(in: "x-ndw4 endpoint=\"https://other.example/auth\"") == nil)
check("endpoint с неявной схемой не принимаем",
      RCITransport.endpoint(in: "x-ndw4 endpoint=\"https:other.example/auth\"") == nil)
check("сетевой endpoint не принимаем",
      RCITransport.endpoint(in: "x-ndw4 endpoint=\"//other.example/auth\"") == nil)
check("endpoint выше корня не принимаем",
      RCITransport.endpoint(in: "x-ndw4 endpoint=\"../auth\"") == nil)

if ProcessInfo.processInfo.environment["SELFTEST_NETWORK"] != nil {
    print("\n== Живая загрузка источников ==")
    for spec in SourceCatalog.all {
        do {
            let data = try SourceLoader.load(spec, ttlMinutes: 0, forceRefresh: true)
            let subnets = data.subnetCount > 0 ? ", подсетей \(data.subnetCount)" : ""
            check("\(spec.title): \(data.entries.count) записей\(subnets)",
                  data.entries.count >= spec.minDomains)
        } catch {
            check("\(spec.title): \(error.localizedDescription)", false)
        }
    }
}

print("\n\(checks - failures)/\(checks) проверок пройдено")
exit(failures == 0 ? 0 : 1)
