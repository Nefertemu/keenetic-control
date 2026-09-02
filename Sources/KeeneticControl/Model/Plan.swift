import Foundation

struct PlannedDnsRoute: Hashable {
    var group: String
    var interface: String
    var auto: Bool
    var reject: Bool

    var assignment: DnsRouteAssignment {
        DnsRouteAssignment(interface: interface, auto: auto, reject: reject)
    }
}

/// План изменений: сначала считаем всё на берегу, показываем — и только потом
/// отправляем на роутер. Один движок на импорт списков и на маршруты.
struct Plan: Identifiable {
    /// Стабильный идентификатор важен для SwiftUI: план показывается в sheet,
    /// и новый UUID при каждой перерисовке заставлял бы окно пересоздаваться.
    let id = UUID()
    /// Роутер, по состоянию которого был составлен план. Чистые планировщики
    /// этого не знают; экран привязывает план перед показом пользователю.
    /// Это не даёт случайно применить команды к другому роутеру после
    /// переключения в боковой панели.
    var routerID: UUID?
    /// Снимок параметров соединения на момент составления плана. Один и тот
    /// же UUID можно отредактировать и направить на другой адрес, поэтому
    /// одного routerID недостаточно: старый план нельзя отправлять в новый
    /// профиль с тем же идентификатором.
    var routerConnectionKey: String?
    var title: String
    var commands: [String] = []
    var adds: [String: Set<String>] = [:]
    var removes: [String: Set<String>] = [:]
    var createdGroups: [FqdnGroup] = []
    /// Маршруты, которые должны существовать после применения, включая
    /// точные значения `auto`/`reject`.
    var routeTargets: [PlannedDnsRoute] = []
    var unrouteTargets: [(group: String, interface: String)] = []
    /// Для планов резервирования одного наличия маршрутов недостаточно:
    /// последовательность строк определяет приоритет интерфейсов. Здесь
    /// хранится ожидаемая полная цепочка каждого изменяемого списка.
    var exactRouteChains: [String: [DnsRouteAssignment]] = [:]
    var notes: [String] = []

    var addCount: Int { adds.values.reduce(0) { $0 + $1.count } }
    var removeCount: Int { removes.values.reduce(0) { $0 + $1.count } }
    var isEmpty: Bool { commands.isEmpty }

    func forRouter(_ routerID: UUID) -> Plan {
        var bound = self
        bound.routerID = routerID
        return bound
    }

    func forRouter(_ router: RouterProfile) -> Plan {
        var bound = self
        bound.routerID = router.id
        bound.routerConnectionKey = router.connectionKey
        return bound
    }

    mutating func addDomain(_ group: String, _ domain: String, command: String) {
        adds[group, default: []].insert(domain)
        commands.append(command)
    }

    mutating func removeDomain(_ group: String, _ domain: String, command: String) {
        removes[group, default: []].insert(domain)
        commands.append(command)
    }

    /// Короткая сводка для интерфейса.
    var summary: [String] {
        var parts: [String] = []
        if addCount > 0 { parts.append("добавить \(Format.domains(addCount))") }
        if removeCount > 0 { parts.append("удалить \(Format.domains(removeCount))") }
        if !createdGroups.isEmpty { parts.append("создать \(Format.lists(createdGroups.count))") }
        if !routeTargets.isEmpty { parts.append("назначить \(Format.routes(routeTargets.count))") }
        if !unrouteTargets.isEmpty { parts.append("снять \(Format.routes(unrouteTargets.count))") }
        return parts
    }
}

/// Проверка управляемой части конфигурации вынесена из сетевой сессии, чтобы
/// одинаково строго проверять как реальный роутер, так и тестовые снимки.
enum PlanVerifier {
    static func problems(plan: Plan, groups: [String: FqdnGroup], limit: Int) -> [String] {
        var problems: [String] = []

        for (ident, domains) in plan.adds {
            let current = groups[ident]?.includes ?? []
            let missing = domains.subtracting(current)
            if !missing.isEmpty {
                let example = missing.sorted().prefix(3).joined(separator: ", ")
                problems.append("\(ident): не добавлено \(missing.count) (\(example)…)")
            }
        }
        for (ident, domains) in plan.removes {
            let remained = domains.intersection(groups[ident]?.includes ?? [])
            if !remained.isEmpty { problems.append("\(ident): не удалено \(remained.count)") }
        }

        // Обычное назначение не заменяет остальные маршруты списка, поэтому
        // здесь требуем только точное наличие интерфейса и флагов.
        for target in plan.routeTargets where plan.exactRouteChains[target.group] == nil {
            guard let group = groups[target.group] else {
                problems.append("\(target.group): список не найден после применения")
                continue
            }
            let actualForInterface = group.routeAssignments.filter {
                $0.interface == target.interface
            }
            guard actualForInterface == [target.assignment] else {
                if let actual = actualForInterface.first {
                    problems.append("\(target.group): маршрут на \(target.interface) появился "
                                    + (actual == target.assignment && actualForInterface.count > 1
                                       ? "дублируется (строк: \(actualForInterface.count))"
                                       : "с другими флагами — ожидалось \(describe(target.assignment)), "
                                         + "получено \(describe(actual))"))
                } else {
                    problems.append("\(target.group): маршрут на \(target.interface) не появился")
                }
                continue
            }
        }

        // Failover-план сначала снимает все старые маршруты выбранного списка,
        // поэтому результат обязан совпасть полностью: и порядок, и флаги,
        // и отсутствие лишних строк.
        for (ident, expected) in plan.exactRouteChains.sorted(by: { $0.key < $1.key }) {
            let group = groups[ident]
            let actual = group?.routeAssignments ?? []
            if let group, actual.count != group.routeLines.count {
                problems.append("\(ident): часть строк маршрутов не распознана, "
                                + "цепочка небезопасна для проверки")
            }
            if actual != expected {
                problems.append("\(ident): цепочка маршрутов не совпала — ожидалось "
                                + describe(expected) + ", получено " + describe(actual))
            }
        }

        for target in plan.unrouteTargets {
            if let group = groups[target.group], group.isRouted(to: target.interface) {
                problems.append("\(target.group): маршрут на \(target.interface) остался")
            }
        }
        for ident in Set(plan.adds.keys).union(plan.removes.keys) {
            if let group = groups[ident], group.includes.count > limit {
                problems.append("\(ident): превышен лимит \(group.includes.count)/\(limit)")
            }
        }
        return problems
    }

    private static func describe(_ assignment: DnsRouteAssignment) -> String {
        var flags: [String] = []
        if assignment.auto { flags.append("auto") }
        if assignment.reject { flags.append("reject") }
        return assignment.interface + (flags.isEmpty ? "" : " [" + flags.joined(separator: ", ") + "]")
    }

    private static func describe(_ assignments: [DnsRouteAssignment]) -> String {
        assignments.isEmpty ? "ничего" : assignments.map(describe).joined(separator: " → ")
    }
}

enum Planner {
    // MARK: - Разбор «своих» списков

    /// «KinoPub» — часть 1, «KinoPub 2» — часть 2. Номер 1 в имени избыточен.
    static func sourceGroupNumber(description: String, spec: SourceSpec) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: spec.descriptionPrefix)
            .replacingOccurrences(of: "\\ ", with: "[\\s:_-]+")
            .replacingOccurrences(of: " ", with: "[\\s:_-]+")
        let text = description.trimmingCharacters(in: .whitespaces)

        if let exact = try? NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive]),
           exact.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return 1
        }
        guard let numbered = try? NSRegularExpression(
            pattern: "^\(escaped)[\\s:_-]+(\\d+)$", options: [.caseInsensitive]),
            let captured = RouterConfigParser.capture(numbered, in: text, group: 1) else { return nil }
        return Int(captured)
    }

    /// Одна часть — просто имя; несколько — все с номерами, включая первую.
    static func canonicalDescription(spec: SourceSpec, number: Int, totalParts: Int) -> String {
        totalParts <= 1 ? spec.descriptionPrefix : "\(spec.descriptionPrefix) \(number)"
    }

    static func managedGroups(_ groups: [String: FqdnGroup], spec: SourceSpec) -> [FqdnGroup] {
        groups.values
            .filter { sourceGroupNumber(description: $0.descriptionText, spec: spec) != nil }
            .sorted {
                let lhs = sourceGroupNumber(description: $0.descriptionText, spec: spec) ?? .max
                let rhs = sourceGroupNumber(description: $1.descriptionText, spec: spec) ?? .max
                return lhs == rhs ? $0.ident < $1.ident : lhs < rhs
            }
    }

    private static func groupsByNumber(_ groups: [FqdnGroup], spec: SourceSpec)
        -> (canonical: [Int: FqdnGroup], repeated: [Int: [FqdnGroup]]) {
        var canonical: [Int: FqdnGroup] = [:]
        var repeated: [Int: [FqdnGroup]] = [:]

        for group in groups {
            guard let number = sourceGroupNumber(description: group.descriptionText, spec: spec) else { continue }
            guard let existing = canonical[number] else {
                canonical[number] = group
                continue
            }
            if repeated[number] == nil { repeated[number] = [existing] }
            repeated[number]?.append(group)
            if group.includes.count > existing.includes.count { canonical[number] = group }
        }
        return (canonical, repeated)
    }

    static func allocateGroupIDs(existing: inout Set<String>, count: Int) -> [String] {
        var result: [String] = []
        var index = 0
        while result.count < count {
            let candidate = "domain-list\(index)"
            if !existing.contains(candidate) {
                result.append(candidate)
                existing.insert(candidate)
            }
            index += 1
        }
        return result
    }

    // MARK: - Импорт списков

    /// Создаёт и пополняет списки источника. Маршруты не трогаются вообще —
    /// это отдельная операция, как и в консольном скрипте.
    static func planImport(
        groups: [String: FqdnGroup],
        data: SourceData,
        chunkSize: Int,
        removeStale: Bool,
        reservedIDs: inout Set<String>
    ) -> Plan {
        let spec = data.spec
        var plan = Plan(title: "\(spec.title): загрузка списков")

        let managed = managedGroups(groups, spec: spec)
        let (byNumber, repeated) = groupsByNumber(managed, spec: spec)

        // Части с повторяющимся номером не трогаем вообще — только предупреждаем.
        let canonical = byNumber.keys.sorted().compactMap { repeated[$0] == nil ? byNumber[$0] : nil }
        let frozen = Set(repeated.values.flatMap { $0 }.map(\.ident))

        if !repeated.isEmpty {
            let numbers = repeated.keys.sorted().map(String.init).joined(separator: ", ")
            plan.notes.append("Повторяются номера частей (\(numbers)) — они не пополняются "
                              + "и не удаляются, разберись с ними вручную.")
        }

        let overLimit = managed.filter { $0.includes.count > chunkSize }
        if !overLimit.isEmpty {
            plan.notes.append("Списки крупнее лимита (пополняться не будут): "
                              + overLimit.map { "\($0.ident)=\($0.includes.count)" }.joined(separator: ", "))
        }

        var routerDomains = Set<String>()
        for group in managed { routerDomains.formUnion(group.includes) }
        let sourceSet = Set(data.entries)

        // 1. Убираем то, чего в источнике больше нет.
        if removeStale {
            for group in managed where !frozen.contains(group.ident) {
                let gone = group.includes.filter { !sourceSet.contains($0) }.sorted()
                for domain in gone {
                    plan.removeDomain(group.ident, domain,
                                      command: "no object-group fqdn \(group.ident) include \(domain)")
                }
            }
        }

        var plannedCounts: [String: Int] = [:]
        for group in canonical {
            plannedCounts[group.ident] = group.includes.count - (plan.removes[group.ident]?.count ?? 0)
        }

        // Домены источника в чужих списках только отмечаем — не трогаем.
        let managedIDs = Set(managed.map(\.ident))
        var foreignHits = 0
        for (ident, group) in groups where !managedIDs.contains(ident) {
            foreignHits += group.includes.intersection(sourceSet).count
        }
        if foreignHits > 0 {
            plan.notes.append("\(Format.domains(foreignHits)) источника уже лежат в других списках "
                              + "роутера — они не трогаются, но маршруты могут конфликтовать.")
        }

        // 2. Раскладываем новое по частям, добивая существующие до лимита.
        let newDomains = data.entries.filter { !routerDomains.contains($0) }
        var createdNumbers: [String: Int] = [:]
        var maxNumber = byNumber.keys.max() ?? 0
        var available = canonical

        reservedIDs.formUnion(groups.keys)

        for domain in newDomains {
            var targetIndex = available.firstIndex { (plannedCounts[$0.ident] ?? 0) < chunkSize }

            if targetIndex == nil {
                maxNumber += 1
                let ident = allocateGroupIDs(existing: &reservedIDs, count: 1)[0]
                let group = FqdnGroup(ident: ident)
                available.append(group)
                plan.createdGroups.append(group)
                createdNumbers[ident] = maxNumber
                plannedCounts[ident] = 0
                plan.commands.append("object-group fqdn \(ident)")
                targetIndex = available.count - 1
            }

            let target = available[targetIndex!]
            plan.addDomain(target.ident, domain,
                           command: "object-group fqdn \(target.ident) include \(domain)")
            plannedCounts[target.ident, default: 0] += 1
        }

        // 3. Приводим имена частей к канону.
        let totalParts = Set(byNumber.keys).union(createdNumbers.values).count
        var renames = 0

        for number in byNumber.keys.sorted() where repeated[number] == nil {
            guard let group = byNumber[number] else { continue }
            let wanted = canonicalDescription(spec: spec, number: number, totalParts: totalParts)
            if group.descriptionText != wanted {
                plan.commands.append("object-group fqdn \(group.ident) description \(CLI.quote(wanted))")
                renames += 1
            }
        }
        for index in plan.createdGroups.indices {
            let ident = plan.createdGroups[index].ident
            let wanted = canonicalDescription(
                spec: spec, number: createdNumbers[ident] ?? 1, totalParts: totalParts)
            plan.createdGroups[index].descriptionText = wanted
            plan.commands.append("object-group fqdn \(ident) description \(CLI.quote(wanted))")
        }

        if renames > 0 { plan.notes.append("Приводятся имена частей: \(renames)") }
        if !plan.createdGroups.isEmpty {
            plan.notes.append("Создаётся новых частей: \(plan.createdGroups.count). "
                              + "Маршрут им НЕ назначается — это отдельная вкладка.")
        }

        return plan
    }

    // MARK: - Маршруты списков

    static func planRoutes(groups: [FqdnGroup], interface: String,
                           auto: Bool, reject: Bool) -> Plan {
        var plan = Plan(title: "Маршруты → \(interface)")
        var skipped = 0
        let wanted = DnsRouteAssignment(interface: interface, auto: auto, reject: reject)

        for group in groups {
            let actualForInterface = group.routeAssignments.filter { $0.interface == interface }
            if actualForInterface == [wanted] { skipped += 1; continue }

            // Тот же интерфейс с другими auto/reject — это не готовый
            // маршрут. Снимаем все его варианты и дубли, чтобы после
            // применения осталась ровно одна однозначная строка.
            for line in group.routeLines where DnsRouteAssignment.parse(line)?.interface == interface {
                plan.commands.append("no " + line)
            }
            var command = "dns-proxy route object-group \(group.ident) \(interface)"
            if auto { command += " auto" }
            if reject { command += " reject" }
            plan.commands.append(command)
            plan.routeTargets.append(PlannedDnsRoute(
                group: group.ident, interface: interface, auto: auto, reject: reject))
        }

        if skipped > 0 {
            plan.notes.append("Уже назначено на \(interface), пропущено: \(Format.lists(skipped))")
        }
        return plan
    }

    /// Назначает списки на несколько интерфейсов в заданном порядке.
    ///
    /// Для резервирования важен не только набор интерфейсов, но и порядок
    /// строк в конфигурации Keenetic. Поэтому для каждого выбранного списка
    /// сначала убираем его старые маршруты, затем добавляем ровно заданную
    /// последовательность. Маршруты других списков и интерфейсов не трогаем.
    static func planRoutes(groups: [FqdnGroup], interfaces: [String],
                           auto: Bool, reject: Bool) -> Plan {
        var ordered: [String] = []
        for interface in interfaces where !interface.isEmpty && !ordered.contains(interface) {
            // Имена приходят из running-config, но всё равно не даём
            // пробелам и управляющим символам превратиться в CLI-команду.
            guard interface.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  !interface.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !interface.contains(where: { "!;|$<>\"'\\".contains($0) }) else { continue }
            ordered.append(interface)
        }

        var plan = Plan(title: ordered.isEmpty
                        ? "Маршруты"
                        : "Маршруты → " + ordered.joined(separator: " → "))
        guard !ordered.isEmpty else { return plan }

        let wantedChain = ordered.map {
            DnsRouteAssignment(interface: $0, auto: auto, reject: reject)
        }
        var reordered = 0
        var skipped = 0
        for group in groups {
            // Список уже направлен ровно так, как просят, — в том же порядке
            // и с теми же флагами. Трогать его нельзя: план снимает маршруты
            // перед тем как назначить заново, и в этот промежуток домены
            // уходят мимо туннеля.
            if group.routeAssignments == wantedChain { skipped += 1; continue }

            let oldRoutes = group.routedInterfaces
            if !group.routeLines.isEmpty {
                for line in group.routeLines {
                    plan.commands.append("no " + line)
                }
                for interface in oldRoutes where !ordered.contains(interface) {
                    plan.unrouteTargets.append((group.ident, interface))
                }
                reordered += 1
            }

            for interface in ordered {
                var command = "dns-proxy route object-group \(group.ident) \(interface)"
                if auto { command += " auto" }
                if reject { command += " reject" }
                plan.commands.append(command)
                plan.routeTargets.append(PlannedDnsRoute(
                    group: group.ident, interface: interface, auto: auto, reject: reject))
            }
            plan.exactRouteChains[group.ident] = ordered.map {
                DnsRouteAssignment(interface: $0, auto: auto, reject: reject)
            }
        }

        if reordered > 0 {
            plan.notes.append("У выбранных списков заменяются старые маршруты и задаётся порядок: "
                              + ordered.joined(separator: " → ") + ".")
        }
        if skipped > 0 {
            plan.notes.append("Уже с нужной последовательностью, не трогаем: "
                              + Format.lists(skipped) + ".")
        }
        if groups.count > skipped {
            plan.notes.append("Маршруты назначаются для \(Format.lists(groups.count - skipped)) "
                              + "на каждый интерфейс в последовательности резервирования.")
        }
        return plan
    }

    static func planUnroute(groups: [FqdnGroup], interface: String) -> Plan {
        var plan = Plan(title: "Снять маршруты с \(interface)")
        for group in groups where group.isRouted(to: interface) {
            plan.commands.append("no dns-proxy route object-group \(group.ident) \(interface)")
            plan.unrouteTargets.append((group.ident, interface))
        }
        return plan
    }

    static func planDeleteGroups(_ groups: [FqdnGroup]) -> Plan {
        var plan = Plan(title: "Удаление списков")
        for group in groups {
            for line in group.routeLines {
                plan.commands.append("no " + line)
            }
            plan.commands.append("no object-group fqdn \(group.ident)")
        }
        if !groups.isEmpty {
            plan.notes.append("Удаляются целиком: " + groups.map(\.ident).joined(separator: ", "))
        }
        return plan
    }

    // MARK: - Перенос списков между роутерами

    /// Дополняет списки текущего роутера тем, чего не хватает по сравнению
    /// с эталонным. Списки сопоставляются по описанию — именно оно, а не
    /// идентификатор, одинаково на разных роутерах. Операция только
    /// добавляющая: лишнее на текущем роутере не трогается, только отмечается.
    static func planSync(reference: [String: FqdnGroup],
                         current: [String: FqdnGroup],
                         chunkSize: Int,
                         reservedIDs: inout Set<String>) -> Plan {
        var plan = Plan(title: "Перенос недостающих доменов")
        reservedIDs.formUnion(current.keys)

        // Группируем по описанию: одна «часть» источника может быть разбита
        // на несколько списков с одинаковым описанием.
        func byDescription(_ groups: [String: FqdnGroup]) -> [String: [FqdnGroup]] {
            var result: [String: [FqdnGroup]] = [:]
            for group in groups.values where !group.descriptionText.isEmpty {
                result[group.descriptionText, default: []].append(group)
            }
            for key in result.keys { result[key]?.sort { $0.ident < $1.ident } }
            return result
        }

        let referenceByName = byDescription(reference)
        let currentByName = byDescription(current)

        var plannedCounts: [String: Int] = [:]
        for group in current.values { plannedCounts[group.ident] = group.includes.count }

        var createdLists = 0
        // Домен, лежащий в любом списке роутера, повторно не добавляем.
        var anywhere = current.values.reduce(into: Set<String>()) { $0.formUnion($1.includes) }

        for name in referenceByName.keys.sorted() {
            let source = referenceByName[name] ?? []
            let sourceDomains = source.reduce(into: Set<String>()) { result, group in
                result.formUnion(group.includes)
            }.sorted()

            var targets = currentByName[name] ?? []
            let missing = sourceDomains.filter { !anywhere.contains($0) }
            guard !missing.isEmpty else { continue }

            for domain in missing {
                var target = targets.first { (plannedCounts[$0.ident] ?? 0) < chunkSize }

                if target == nil {
                    let ident = allocateGroupIDs(existing: &reservedIDs, count: 1)[0]
                    var created = FqdnGroup(ident: ident)
                    created.descriptionText = name
                    targets.append(created)
                    plan.createdGroups.append(created)
                    plannedCounts[ident] = 0
                    createdLists += 1
                    plan.commands.append("object-group fqdn \(ident)")
                    plan.commands.append("object-group fqdn \(ident) description \(CLI.quote(name))")
                    target = created
                }

                guard let chosen = target else { continue }
                plan.addDomain(chosen.ident, domain,
                               command: "object-group fqdn \(chosen.ident) include \(domain)")
                plannedCounts[chosen.ident, default: 0] += 1
                // Следующая группа эталона тоже может содержать этот домен.
                // После планирования считаем его уже присутствующим, иначе
                // получим две одинаковые команды или два разных списка.
                anywhere.insert(domain)
            }
        }

        // То, чего нет на эталонном роутере, — просто сообщаем.
        let referenceDomains = reference.values.reduce(into: Set<String>()) { $0.formUnion($1.includes) }
        let currentDomains = current.values.reduce(into: Set<String>()) { $0.formUnion($1.includes) }
        let extra = currentDomains.subtracting(referenceDomains)
        if !extra.isEmpty {
            plan.notes.append("На этом роутере есть \(Format.domains(extra.count)), которых нет "
                              + "у эталонного. Они не трогаются.")
        }

        let missingNames = Set(referenceByName.keys).subtracting(currentByName.keys)
        if !missingNames.isEmpty {
            plan.notes.append("Списков не было вовсе: " + missingNames.sorted().joined(separator: ", "))
        }
        if createdLists > 0 {
            plan.notes.append("Создаётся новых частей: \(createdLists). "
                              + "Маршруты им не назначаются — это отдельная вкладка.")
        }

        return plan
    }

    /// Сначала все удаления, потом создание списков и добавления.
    static func merge(title: String, plans: [Plan]) -> Plan {
        var merged = Plan(title: title)
        let owners = Set(plans.compactMap(\.routerID))
        if owners.count == 1 { merged.routerID = owners.first }
        let connectionKeys = Set(plans.compactMap(\.routerConnectionKey))
        if owners.count == 1, connectionKeys.count == 1,
           plans.allSatisfy({ $0.routerConnectionKey != nil }) {
            merged.routerConnectionKey = connectionKeys.first
        }
        var removals: [String] = []
        var additions: [String] = []

        for plan in plans {
            for command in plan.commands {
                if command.hasPrefix("no object-group fqdn ") { removals.append(command) }
                else { additions.append(command) }
            }
            for (ident, domains) in plan.adds { merged.adds[ident, default: []].formUnion(domains) }
            for (ident, domains) in plan.removes { merged.removes[ident, default: []].formUnion(domains) }
            merged.createdGroups.append(contentsOf: plan.createdGroups)
            merged.routeTargets.append(contentsOf: plan.routeTargets)
            merged.unrouteTargets.append(contentsOf: plan.unrouteTargets)
            for (group, chain) in plan.exactRouteChains {
                merged.exactRouteChains[group] = chain
            }
            merged.notes.append(contentsOf: plan.notes)
        }

        var seen = Set<String>()
        for command in removals + additions where !seen.contains(command) {
            seen.insert(command)
            merged.commands.append(command)
        }
        return merged
    }
}

/// Планировщик небольших списков, которые удобнее ввести прямо в приложении
/// (например, тестовый список `test`), чем заводить отдельным URL-источником.
/// Такой список живёт на роутере как обычный object-group и дальше виден во
/// вкладке «Маршруты списков» вместе со всеми загруженными источниками.
enum ManualFqdnPlanner {
    static func plan(ident rawIdent: String, description rawDescription: String,
                     entriesText: String) throws -> Plan {
        let ident = rawIdent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ident.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
            throw TransportError("Имя списка должно начинаться с латинской буквы и содержать "
                                 + "только латиницу, цифры, дефис или подчёркивание (до 32 символов).")
        }

        let description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            throw TransportError("Укажи описание списка.")
        }
        guard !description.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TransportError("Описание списка не может содержать переводы строк или служебные символы.")
        }

        let parsed = Domains.parseList(entriesText)
        guard !parsed.domains.isEmpty else {
            throw TransportError("В списке нет ни одного корректного домена или IP-адреса.")
        }
        guard parsed.skipped.isEmpty else {
            let examples = parsed.skipped.prefix(3).joined(separator: ", ")
            throw TransportError("Не удалось распознать \(parsed.skipped.count) строк: \(examples)",
                                 hint: "Исправь их или убери из списка — ничего не будет пропущено молча.")
        }

        var plan = Plan(title: "Создание списка «\(ident)»")
        var group = FqdnGroup(ident: ident, descriptionText: description)
        group.includes = Set(parsed.domains)
        plan.createdGroups = [group]
        plan.commands.append("object-group fqdn \(ident)")
        plan.commands.append("object-group fqdn \(ident) description \(CLI.quote(description))")
        for domain in parsed.domains {
            plan.addDomain(ident, domain,
                           command: "object-group fqdn \(ident) include \(domain)")
        }
        plan.notes.append("Список создаётся без маршрута. Назначь его во вкладке «Маршруты списков».")
        return plan
    }
}
