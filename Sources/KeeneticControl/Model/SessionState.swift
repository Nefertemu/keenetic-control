import Foundation
import SwiftUI

enum ConnectionStatus: Equatable {
    case offline
    case connecting
    case online(TransportKind)
    case failed(String)

    var isOnline: Bool { if case .online = self { return true }; return false }
    var isBusy: Bool { self == .connecting }

    var title: String {
        switch self {
        case .offline:            return "Не подключено"
        case .connecting:         return "Подключаюсь…"
        case .online(let kind):   return "На связи · \(kind.shortTitle)"
        case .failed:             return "Ошибка связи"
        }
    }

    var tint: Color {
        switch self {
        case .offline:    return .secondary
        case .connecting: return .orange
        case .online:     return .green
        case .failed:     return .red
        }
    }
}

struct RouterState {
    var configText: String = ""
    var groups: [String: FqdnGroup] = [:]
    var interfaces: [String: KeeneticInterface] = [:]
    var candidates: [KeeneticInterface] = []
    var staticRoutes: [StaticRoute] = []
    var wireguardInterfaces: [String] = []
    var pingCheckProfiles: [PingCheckProfile] = []
    var pingCheckBindings: [String: PingCheckBinding] = [:]
    var readAt: Date = Date()

    var sortedGroups: [FqdnGroup] { RouterConfigParser.sortedGroups(groups) }

    /// Примечание интерфейса из конфигурации роутера — то же, что видно
    /// в веб-панели рядом с именем.
    /// Интерфейс по имени, каким его называют команды.
    ///
    /// В маршрутах Keenetic встречается не только идентификатор вида
    /// `GigabitEthernet1`, но и его обиходное имя — например `ISP` у
    /// подключения к провайдеру. Поиск строго по ключу такой интерфейс не
    /// находил, и приложение объявляло рабочий маршрут «ведущим в никуда».
    func interface(named ident: String) -> KeeneticInterface? {
        if let exact = interfaces[ident] { return exact }
        // Синоним теоретически может принадлежать нескольким интерфейсам —
        // выбираем предсказуемо, а не как ляжет обход словаря.
        return interfaces.values
            .filter { $0.aliases.contains(ident) }
            .sorted { $0.ident < $1.ident }
            .first
    }

    /// Есть ли на роутере интерфейс с таким именем.
    func hasInterface(_ ident: String) -> Bool { interface(named: ident) != nil }

    func note(for ident: String) -> String? {
        let note = interface(named: ident)?.descriptionText ?? ""
        return note.isEmpty ? nil : note
    }

    /// «Dataforest · Wireguard0» — сначала имя, которое дал человек.
    func label(for ident: String) -> String {
        guard let note = note(for: ident) else { return ident }
        return "\(note) · \(ident)"
    }

    /// Назначен ли интерфейсу профиль проверки связи.
    func hasPingCheck(_ ident: String) -> Bool {
        !(pingCheckBindings[ident]?.profile ?? "").isEmpty
    }

    /// Что роутер думает о проверке связи на этом интерфейсе сейчас.
    func pingCheck(for ident: String) -> PingCheckLiveState {
        interfaces[ident]?.pingCheck(configured: hasPingCheck(ident)) ?? .notConfigured
    }

    /// Как назвать интерфейс одним словом там, где места мало.
    func shortLabel(for ident: String) -> String { note(for: ident) ?? ident }

    /// Несколько интерфейсов одной строкой. Названные идут своими именами
    /// («Dataforest, Infomaniak»), безымянные из одного семейства
    /// сворачиваются в «Wireguard 0, 3» — иначе слово повторяется впустую.
    func targetSummary(_ idents: [String]) -> String {
        var named: [String] = []
        var families: [(family: String, numbers: [String])] = []

        for ident in idents {
            if let note = note(for: ident) { named.append(note); continue }
            let parts = InterfaceName.split(ident)
            guard let number = parts.number else { named.append(ident); continue }
            if let index = families.firstIndex(where: { $0.family == parts.family }) {
                if !families[index].numbers.contains(number) {
                    families[index].numbers.append(number)
                }
            } else {
                families.append((parts.family, [number]))
            }
        }

        let collapsed = families.map { item -> String in
            item.numbers.count == 1
                ? item.family + item.numbers[0]
                : item.family + " " + item.numbers.joined(separator: ", ")
        }
        return (named + collapsed).joined(separator: ", ")
    }

    /// Полная расшифровка для подсказки: по строке на интерфейс.
    func targetTooltip(_ idents: [String]) -> String {
        idents.map { label(for: $0) }.joined(separator: "\n")
    }
    var totalDomains: Int { groups.values.reduce(0) { $0 + $1.includes.count } }
    var routedGroups: Int { groups.values.filter { !$0.routeLines.isEmpty }.count }

    /// DNS-серверы из running-config. Они нужны только для диагностики:
    /// приложение не меняет их и не пытается угадывать настройки DNS.
    /// Адреса DNS-серверов роутера.
    ///
    /// В строке `ip name-server` за адресом идут ещё домен и привязка к
    /// интерфейсу — например `ip name-server 1.1.1.1 "" on Wireguard0`.
    /// Раньше в список попадали все слова подряд, и рядом с адресами
    /// оказывались `""`, `on` и имена интерфейсов, выданные за серверы.
    var nameServers: [String] {
        var result: [String] = []
        for raw in configText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("ip name-server ") else { continue }
            // Берём адреса с начала строки и останавливаемся на первом слове,
            // которое адресом не является.
            for value in line.dropFirst("ip name-server ".count)
                .split(whereSeparator: { $0.isWhitespace }) {
                let server = String(value)
                guard IPTools.isIP(server) else { break }
                if !result.contains(server) { result.append(server) }
            }
        }
        return result
    }
}

/// Последнее замеченное изменение конфигурации роутера.
///
/// Фоновое перечитывание умело сказать «конфигурация изменилась», но не
/// что именно. А правки приходят и из веб-панели роутера, так что вопрос
/// «что там поменялось, пока меня не было» — рабочий.
struct RouterChange {
    var at: Date
    var difference: Restore.Difference

    /// Пусто — поменялось что-то, чем приложение не управляет (Wi-Fi,
    /// NAT, межсетевой экран), и выдавать это за правку списков нельзя.
    var touchesManagedSettings: Bool { !difference.isEmpty }

    /// Сводка «что стало другим».
    ///
    /// `Restore.Difference` описывает разницу словами возврата к копии
    /// («вернуть», «убрать»), а здесь смысл обратный: слева прошлое
    /// состояние, справа текущее. Поэтому формулировки свои.
    var lines: [String] {
        var result: [String] = []
        if difference.extraDomainCount > 0 {
            result.append(Format.agree(difference.extraDomainCount, "добавлен", "добавлено")
                          + " \(Format.domains(difference.extraDomainCount))"
                          + placeSuffix(Array(difference.extraDomains.keys)))
        }
        if difference.missingDomainCount > 0 {
            result.append(Format.agree(difference.missingDomainCount, "убран", "убрано")
                          + " \(Format.domains(difference.missingDomainCount))"
                          + placeSuffix(Array(difference.missingDomains.keys), preposition: "из"))
        }
        if !difference.extraGroups.isEmpty {
            result.append(Format.agree(difference.extraGroups.count, "появился", "появилось")
                          + " \(Format.lists(difference.extraGroups.count))"
                          + listNames(difference.extraGroups.map(\.ident)))
        }
        if !difference.missingGroups.isEmpty {
            result.append(Format.agree(difference.missingGroups.count, "удалён", "удалено")
                          + " \(Format.lists(difference.missingGroups.count))"
                          + listNames(difference.missingGroups.map(\.ident)))
        }
        if difference.extraRouteCount > 0 {
            result.append("назначено маршрутов списков: \(difference.extraRouteCount)")
        }
        if difference.missingRouteCount > 0 {
            result.append("снято маршрутов списков: \(difference.missingRouteCount)")
        }
        if !difference.reorderedRouteGroups.isEmpty {
            result.append("изменён порядок маршрутов" + placeSuffix(difference.reorderedRouteGroups, preposition: "у"))
        }
        if !difference.extraRoutes.isEmpty {
            result.append(Format.agree(difference.extraRoutes.count, "добавлен", "добавлено")
                          + " \(Format.routes(difference.extraRoutes.count))")
        }
        if !difference.missingRoutes.isEmpty {
            result.append(Format.agree(difference.missingRoutes.count, "удалён", "удалено")
                          + " \(Format.routes(difference.missingRoutes.count))")
        }
        return result
    }

    /// Имя, которое списку дал человек; идентификатор — когда имени нет.
    private func name(_ ident: String) -> String {
        let text = (difference.currentGroups[ident] ?? difference.snapshotGroups[ident])?
            .descriptionText ?? ""
        return text.isEmpty ? ident : "«\(text)»"
    }

    private func ordered(_ idents: [String]) -> [String] {
        idents.sorted { RouterConfigParser.identOrder($0) < RouterConfigParser.identOrder($1) }
    }

    /// «в «youtube»», «из «meta» и «test»», «в 3 списках» — где именно
    /// поменялись записи. Десяток имён в одну строку не вываливаем.
    private func placeSuffix(_ idents: [String], preposition: String = "в") -> String {
        let sorted = ordered(idents)
        switch sorted.count {
        case 0: return ""
        case 1: return " \(preposition) \(name(sorted[0]))"
        case 2: return " \(preposition) \(name(sorted[0])) и \(name(sorted[1]))"
        default:
            return preposition == "в"
                ? " в \(Format.inLists(sorted.count))"
                : " \(preposition) \(Format.plural(sorted.count, "списка", "списков", "списков"))"
        }
    }

    /// Сами появившиеся или удалённые списки: «появился 1 список: «meta»».
    /// Раньше имя пристёгивалось предлогом — «появился 1 список в domain-list2».
    private func listNames(_ idents: [String]) -> String {
        let sorted = ordered(idents)
        guard !sorted.isEmpty, sorted.count <= 3 else { return "" }
        return ": " + sorted.map(name).joined(separator: ", ")
    }
}

struct ProgressInfo: Equatable {
    var label: String
    var done: Int
    var total: Int
    var started: Date = Date()

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    var eta: String? {
        let elapsed = Date().timeIntervalSince(started)
        guard done > 0, elapsed > 1, done < total else { return nil }
        let rate = Double(done) / elapsed
        guard rate > 0 else { return nil }
        return Format.duration(Double(total - done) / rate)
    }
}

struct ApplyOutcome: Identifiable {
    let id = UUID()
    var applied: Bool
    var problems: [String] = []
    var backupURL: URL?
    var elapsed: TimeInterval = 0
    var historyID: UUID?
}

/// Снимок конкретного подключения, с которым началась длинная операция.
/// UUID сам по себе не достаточен: пользователь может отредактировать тот же
/// профиль и направить его на другой роутер, пока операция ждёт сеть.
struct RouterOperation: Equatable {
    let routerID: UUID
    let connectionKey: String
    let generation: Int
}
