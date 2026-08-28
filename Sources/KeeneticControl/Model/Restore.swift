import Foundation

/// Возврат к состоянию из резервной копии.
///
/// Приложение отвечает только за то, чем управляет само: списки FQDN, их
/// маршруты через dns-proxy и статические маршруты. Wi-Fi, NAT, межсетевой
/// экран и всё остальное из копии НЕ трогаются — иначе «откат» мог бы
/// снести настройки, которые к делу не относятся.
enum Restore {

    /// Чем текущая конфигурация отличается от снимка.
    struct Difference {
        /// Домены, появившиеся после снимка, — их надо убрать.
        var extraDomains: [String: Set<String>] = [:]
        /// Домены, пропавшие после снимка, — их надо вернуть.
        var missingDomains: [String: Set<String>] = [:]
        /// Списки, которых в снимке не было, — удалить целиком.
        var extraGroups: [FqdnGroup] = []
        /// Списки, бывшие в снимке и исчезнувшие, — создать заново.
        var missingGroups: [FqdnGroup] = []
        /// Строки маршрутов dns-proxy: лишние и недостающие.
        var extraRouteLines: [String] = []
        var missingRouteLines: [String] = []
        /// Статические маршруты.
        var extraRoutes: [StaticRoute] = []
        var missingRoutes: [StaticRoute] = []

        var extraDomainCount: Int { extraDomains.values.reduce(0) { $0 + $1.count } }
        var missingDomainCount: Int { missingDomains.values.reduce(0) { $0 + $1.count } }

        var isEmpty: Bool {
            extraDomains.isEmpty && missingDomains.isEmpty
                && extraGroups.isEmpty && missingGroups.isEmpty
                && extraRouteLines.isEmpty && missingRouteLines.isEmpty
                && extraRoutes.isEmpty && missingRoutes.isEmpty
        }

        /// Человеческая сводка — то же, что попадёт в заголовок плана.
        var summary: [String] {
            var parts: [String] = []
            if missingDomainCount > 0 { parts.append("вернуть \(Format.domains(missingDomainCount))") }
            if extraDomainCount > 0 { parts.append("убрать \(Format.domains(extraDomainCount))") }
            if !missingGroups.isEmpty { parts.append("создать \(Format.lists(missingGroups.count))") }
            if !extraGroups.isEmpty { parts.append("удалить \(Format.lists(extraGroups.count))") }
            let routes = missingRouteLines.count + extraRouteLines.count
            if routes > 0 { parts.append("маршрутов списков: \(routes)") }
            let statics = missingRoutes.count + extraRoutes.count
            if statics > 0 { parts.append("статических маршрутов: \(statics)") }
            return parts
        }
    }

    static func compare(backup: String, current: String) -> Difference {
        let before = RouterConfigParser.parseFqdnGroups(CLI.normalizeNewlines(backup))
        let after = RouterConfigParser.parseFqdnGroups(CLI.normalizeNewlines(current))
        var difference = Difference()

        for (ident, old) in before {
            guard let new = after[ident] else {
                difference.missingGroups.append(old)
                continue
            }
            let gone = old.includes.subtracting(new.includes)
            let added = new.includes.subtracting(old.includes)
            if !gone.isEmpty { difference.missingDomains[ident] = gone }
            if !added.isEmpty { difference.extraDomains[ident] = added }
        }
        for (ident, new) in after where before[ident] == nil {
            difference.extraGroups.append(new)
        }

        // Маршруты списков сверяем построчно: строка целиком и есть команда.
        let oldRoutes = Set(before.values.flatMap(\.routeLines))
        let newRoutes = Set(after.values.flatMap(\.routeLines))
        // Списки, которые целиком уходят или приходят, уносят маршруты с собой.
        let handled = Set(difference.extraGroups.flatMap(\.routeLines))
            .union(difference.missingGroups.flatMap(\.routeLines))
        difference.missingRouteLines = oldRoutes.subtracting(newRoutes)
            .subtracting(handled).sorted()
        difference.extraRouteLines = newRoutes.subtracting(oldRoutes)
            .subtracting(handled).sorted()

        let oldStatic = StaticRouteParser.parse(config: CLI.normalizeNewlines(backup))
        let newStatic = StaticRouteParser.parse(config: CLI.normalizeNewlines(current))
        let oldKeys = Set(oldStatic.map(\.id))
        let newKeys = Set(newStatic.map(\.id))
        difference.missingRoutes = oldStatic.filter { !newKeys.contains($0.id) }
        difference.extraRoutes = newStatic.filter { !oldKeys.contains($0.id) }

        return difference
    }

    /// План возврата. Порядок важен: сначала убираем лишнее, потом
    /// восстанавливаем недостающее, маршруты — после самих списков.
    static func plan(_ difference: Difference, chunkSize: Int, title: String) -> Plan {
        var plan = Plan(title: title)

        // 1. Маршруты, которых в снимке не было, — снять до правки списков.
        for line in difference.extraRouteLines {
            plan.commands.append("no " + line)
        }

        // 2. Списки, появившиеся после снимка, — удалить целиком.
        for group in difference.extraGroups {
            for line in group.routeLines { plan.commands.append("no " + line) }
            plan.commands.append("no object-group fqdn \(group.ident)")
        }

        // 3. Лишние домены внутри уцелевших списков.
        for ident in difference.extraDomains.keys.sorted() {
            for domain in (difference.extraDomains[ident] ?? []).sorted() {
                plan.removeDomain(ident, domain,
                                  command: "no object-group fqdn \(ident) include \(domain)")
            }
        }

        // 4. Списки, исчезнувшие после снимка, — создать заново.
        for group in difference.missingGroups.sorted(by: { $0.ident < $1.ident }) {
            plan.commands.append("object-group fqdn \(group.ident)")
            if !group.descriptionText.isEmpty {
                plan.commands.append(
                    "object-group fqdn \(group.ident) description \(CLI.quote(group.descriptionText))")
            }
            plan.createdGroups.append(group)
            for domain in group.includes.sorted() {
                plan.addDomain(group.ident, domain,
                               command: "object-group fqdn \(group.ident) include \(domain)")
            }
        }

        // 5. Домены, пропавшие из уцелевших списков.
        for ident in difference.missingDomains.keys.sorted() {
            for domain in (difference.missingDomains[ident] ?? []).sorted() {
                plan.addDomain(ident, domain,
                               command: "object-group fqdn \(ident) include \(domain)")
            }
        }

        // 6. Маршруты списков возвращаем последними — списки уже на месте.
        for line in difference.missingRouteLines {
            plan.commands.append(line)
        }
        for group in difference.missingGroups {
            for line in group.routeLines { plan.commands.append(line) }
        }

        // 7. Статические маршруты.
        for route in difference.extraRoutes { plan.commands.append(route.deleteCommand) }
        for route in difference.missingRoutes { plan.commands.append(route.command) }

        var notes = ["Возвращается только то, чем управляет приложение: списки FQDN, "
                     + "их маршруты и статические маршруты. Остальная конфигурация роутера "
                     + "остаётся как есть."]
        let oversized = difference.missingGroups.filter { $0.includes.count > chunkSize }
        if !oversized.isEmpty {
            notes.append("В снимке есть списки крупнее \(chunkSize) записей "
                         + "(\(oversized.map { "\($0.ident)=\($0.includes.count)" }.joined(separator: ", ")))"
                         + " — восстанавливаются как были.")
        }
        plan.notes = notes
        return plan
    }
}
