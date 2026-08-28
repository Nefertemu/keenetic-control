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
        !
    ip address 10.7.0.2 255.255.255.0
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
ip route 10.50.0.0 255.255.0.0 Wireguard0 auto !корпоративка
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
check("default", routes[1].destination, "default")
check("ipv6", routes[2].destination, "2001:db8::/32")
check("reject", routes[3].reject)
check("команда собирается обратно",
      routes[0].command, "ip route 10.50.0.0 255.255.0.0 Wireguard0 auto !корпоративка")
check("удаление берёт исходную строку",
      routes[3].deleteCommand, "no ip route 203.0.113.77 ISP reject")

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

let live = WireGuardState.parse(config: sampleConfig, interface: "Wireguard0")
check("пир прочитан", live.peerKeys == ["aBcDeFgH1234567890abcdefghijklmnopqrstuv="])
check("порт прочитан", live.listenPort, "51820")
check("интерфейс поднят", live.isUp)
check("список wg-интерфейсов", WireGuardState.interfaceNames(config: sampleConfig) == ["Wireguard0"])

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

print("\n== Планировщик маршрутов ==")
let routePlan = Planner.planRoutes(groups: Array(groups.values), interface: "ISP", auto: true, reject: false)
check("2 команды маршрутов", String(routePlan.commands.count), "2")
check("формат команды", routePlan.commands.allSatisfy { $0.hasSuffix(" ISP auto") })
let skipPlan = Planner.planRoutes(groups: Array(groups.values), interface: "Wireguard0", auto: true, reject: false)
check("уже назначенное пропускается", skipPlan.isEmpty)

print("\n== Детектор ошибок CLI ==")
check("error[code]", CLI.failed("Command::Base error[7405600]: no such interface"))
check("unknown command", CLI.failed("unknown command"))
check("домен со словом error не ложное срабатывание",
      !CLI.failed("object-group fqdn domain-list0 include error-tracker.example.com"))
check("пустой вывод чистый", !CLI.failed(""))
check("кавычки CLI", CLI.quote("itdog ru inside 2"), "\"itdog ru inside 2\"")
check("раскавычивание", CLI.unquote("\"itdog ru inside 2\""), "itdog ru inside 2")
check("ANSI вычищается", CLI.stripNoise("\u{1B}[32mok\u{1B}[0m\r\n"), "ok\n")

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

print("\n== Ping-Check ==")
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
check("команды профиля собираются обратно",
      PingCheckParser.planSave(vpn!, existing: vpn!).commands.joined(separator: " | "),
      "ping-check profile vpn | ping-check profile vpn mode icmp | "
      + "ping-check profile vpn host google.com | ping-check profile vpn update-interval 3 | "
      + "ping-check profile vpn max-fails 3 | ping-check profile vpn min-success 3")
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
} else {
    check("файл настроек прошлой версии читается", false)
}
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
ip route 10.50.0.0 255.255.0.0 Wireguard0 auto
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
      restoreText.contains("ip route 10.50.0.0 255.255.0.0 Wireguard0 auto"))
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
check("префикс встроенного источника занят",
      sourceError(CustomSource(title: "Мой", descriptionPrefix: "kinopub",
                               urls: ["https://a/x"])) != nil)

let mine = CustomSource(title: "Мой", descriptionPrefix: "my list", urls: ["https://a/x"])
check("ключ своего источника отличим", mine.spec.key.hasPrefix("custom-"))
check("свой кэш отдельным файлом", mine.spec.cacheName.hasPrefix("custom-"))
check("путь к файлу не переписывается под github",
      SourceSpec.rawGitHub("/tmp/github.com/x.txt"), "/tmp/github.com/x.txt")

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
    status: 401, data: ["salt": "///", "iterations": 3, "memory": 4096]))
check("нечитаемая соль — несовместимость", badSalt?.handshakeUnsupported ?? false)

let wildParameters = ndw4Failure(NDW4.Reply(
    status: 401,
    data: ["salt": Data(repeating: 7, count: 16).base64EncodedString(),
           "iterations": 9999, "memory": 4096]))
check("неправдоподобные параметры — несовместимость",
      wildParameters?.handshakeUnsupported ?? false)

check("до отказа схему не пропускаем", !RCITransport.skipsModernAuth(host: "192.168.1.1"))
RCITransport.rememberModernAuthUnusable(host: "192.168.1.1")
check("после отказа пропускаем", RCITransport.skipsModernAuth(host: "192.168.1.1"))
check("и только для этого адреса", !RCITransport.skipsModernAuth(host: "192.168.1.2"))

check("разбор endpoint из WWW-Authenticate",
  RCITransport.endpoint(in: "x-ndw4-interactive endpoint=\"/auth\" data=\"e30=\"") ?? "nil", "auth")
check("endpoint отсутствует — не выдумываем",
  RCITransport.endpoint(in: "x-ndw2-interactive realm=\"X\"") == nil)

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
