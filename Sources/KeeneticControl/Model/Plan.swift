import Foundation

/// План изменений: сначала считаем всё на берегу, показываем — и только потом
/// отправляем на роутер. Один движок на импорт списков и на маршруты.
struct Plan {
    var title: String
    var commands: [String] = []
    var adds: [String: Set<String>] = [:]
    var removes: [String: Set<String>] = [:]
    var createdGroups: [FqdnGroup] = []
    var routeTargets: [(group: String, interface: String)] = []
    var unrouteTargets: [(group: String, interface: String)] = []
    var notes: [String] = []

    var addCount: Int { adds.values.reduce(0) { $0 + $1.count } }
    var removeCount: Int { removes.values.reduce(0) { $0 + $1.count } }
    var isEmpty: Bool { commands.isEmpty }

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

        for group in groups {
            if group.isRouted(to: interface) { skipped += 1; continue }
            var command = "dns-proxy route object-group \(group.ident) \(interface)"
            if auto { command += " auto" }
            if reject { command += " reject" }
            plan.commands.append(command)
            plan.routeTargets.append((group.ident, interface))
        }

        if skipped > 0 {
            plan.notes.append("Уже назначено на \(interface), пропущено: \(Format.lists(skipped))")
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
        let anywhere = current.values.reduce(into: Set<String>()) { $0.formUnion($1.includes) }

        for name in referenceByName.keys.sorted() {
            let source = referenceByName[name] ?? []
            let sourceDomains = source.reduce(into: [String]()) { result, group in
                result.append(contentsOf: group.includes.sorted())
            }

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
