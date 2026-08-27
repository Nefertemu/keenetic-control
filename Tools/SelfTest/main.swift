import Foundation

var failures = 0
var checks = 0

func check(_ name: String, _ actual: String, _ expected: String) {
    checks += 1
    if actual == expected { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)\n       ждали: \(expected)\n       вышло: \(actual)") }
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
