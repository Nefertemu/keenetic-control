import Foundation

/// Полная синхронизация уже установленных источников. Существующие части
/// сохраняют имена и маршруты; неизменившиеся записи остаются на своих местах.
enum DomainListSyncPlanner {
    static let maximumEntries = FqdnLimits.maximumEntries

    static func plan(groups: [String: FqdnGroup], data: SourceData,
                     chunkSize: Int = maximumEntries,
                     reservedIDs: inout Set<String>) throws -> Plan {
        let spec = data.spec
        var result = Plan(title: "\(spec.title): обновление списков")
        let managed = Planner.managedGroups(groups, spec: spec)
        guard !managed.isEmpty else { return result }

        guard !data.fromCache else {
            throw TransportError("\(spec.title): источник не удалось скачать заново.",
                                 hint: "Списки на роутере сохранены. Повтори обновление, когда источник будет доступен.")
        }
        guard data.skipped.isEmpty else {
            throw TransportError("\(spec.title): источник распознан не полностью.",
                                 hint: "Пропущено строк: \(data.skipped.count). Чтобы не удалить нужные домены, этот источник не обновлялся.")
        }
        guard !spec.descriptionPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !spec.descriptionPrefix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TransportError("\(spec.title): некорректное имя источника.")
        }

        // SourceLoader уже разбирает исходные форматы. Дополнительная проверка
        // не позволяет подставленному/неполноценному результату удалить списки.
        var desired: [String] = []
        var desiredSet = Set<String>()
        for entry in data.entries {
            guard let value = Domains.normalize(entry) else {
                throw TransportError("\(spec.title): в загруженном списке есть некорректная запись.",
                                     hint: "Обновление этого источника отменено; его списки не изменены.")
            }
            if desiredSet.insert(value).inserted { desired.append(value) }
        }
        let subnets = Set((data.subnetsV4 + data.subnetsV6).compactMap(Domains.normalize))
        guard !desired.isEmpty,
              desiredSet.subtracting(subnets).count >= max(1, spec.minDomains) else {
            throw TransportError("\(spec.title): источник вернул слишком мало записей.",
                                 hint: "Пустой или неполный ответ не используется для удаления доменов.")
        }

        var partNumbers = Set<Int>()
        var commonChain: [DnsRouteAssignment]?
        for group in managed {
            guard let number = Planner.sourceGroupNumber(description: group.descriptionText, spec: spec),
                  number > 0, partNumbers.insert(number).inserted else {
                throw TransportError("\(spec.title): номера частей повторяются или некорректны.",
                                     hint: "У каждой части должен быть свой номер: 1, 2, 3…")
            }
            guard safeToken(group.ident), group.includes.allSatisfy(safeToken) else {
                throw TransportError("\(spec.title): список \(group.ident) содержит неподдерживаемую запись.")
            }
            let chain = try validatedRouteChain(group, sourceTitle: spec.title)
            if let commonChain, commonChain != chain {
                throw TransportError("\(spec.title): части списка направлены по разным маршрутам.",
                                     hint: "Выбери одинаковую цепочку интерфейсов для всех частей во вкладке «Маршруты списков», затем повтори обновление.")
            }
            commonChain = chain
        }
        let chain = commonChain ?? []
        let limit = FqdnLimits.effective(chunkSize: chunkSize)
        result.groupEntryLimit = limit
        result.verifyBeforeSave = true
        result.domainListBaselines = [DomainListBaseline(spec: spec, groups:
            Dictionary(uniqueKeysWithValues: managed.map { ($0.ident, $0) }))]

        // Сначала оставляем действующие записи в прежних частях. Дубли между
        // частями занимают место зря; сохраняется их первое вхождение.
        var assigned = Set<String>()
        var targets: [String: Set<String>] = [:]
        for group in managed {
            var kept = Set<String>()
            for entry in group.includes.sorted() where desiredSet.contains(entry) {
                if kept.count < limit, assigned.insert(entry).inserted { kept.insert(entry) }
            }
            targets[group.ident] = kept
        }

        // Новые записи заполняют свободные места. Только после этого создаются
        // дополнительные части; никакой перенумерации старых списков не нужно.
        var available = managed.map(\.ident)
        var availableIndex = 0
        var createdNumbers: [String: Int] = [:]
        var nextNumber = partNumbers.max() ?? 0
        var allocated = reservedIDs.union(groups.keys)
        for entry in desired where !assigned.contains(entry) {
            while availableIndex < available.count,
                  targets[available[availableIndex], default: []].count >= limit {
                availableIndex += 1
            }
            if availableIndex == available.count {
                guard nextNumber < Int.max else {
                    throw TransportError("\(spec.title): слишком большой номер части.")
                }
                nextNumber += 1
                let ident = Planner.allocateGroupIDs(existing: &allocated, count: 1)[0]
                available.append(ident)
                targets[ident] = []
                createdNumbers[ident] = nextNumber
            }
            let ident = available[availableIndex]
            targets[ident, default: []].insert(entry)
            assigned.insert(entry)
        }

        // Удаления освобождают место до первой include-команды, в том числе
        // при исправлении уже существующей части крупнее 300 записей.
        for group in managed {
            for entry in group.includes.subtracting(targets[group.ident] ?? []).sorted() {
                result.removeDomain(group.ident, entry,
                    command: "no object-group fqdn \(group.ident) include \(entry)")
            }
        }
        for ident in available where createdNumbers[ident] != nil {
            let description = Planner.canonicalDescription(spec: spec,
                number: createdNumbers[ident]!, totalParts: available.count)
            var created = FqdnGroup(ident: ident, descriptionText: description)
            result.commands.append("object-group fqdn \(ident)")
            result.commands.append("object-group fqdn \(ident) description \(CLI.quote(description))")
            // Сначала маршруты, потом include: новая часть с первого домена
            // использует ту же цепочку и флаги, что и установленные части.
            for assignment in chain {
                var command = "dns-proxy route object-group \(ident) \(assignment.interface)"
                if assignment.auto { command += " auto" }
                if assignment.reject { command += " reject" }
                result.commands.append(command)
                created.routeLines.append(command)
                result.routeTargets.append(PlannedDnsRoute(group: ident,
                    interface: assignment.interface, auto: assignment.auto, reject: assignment.reject))
            }
            result.createdGroups.append(created)
        }
        for ident in available {
            let contents = targets[ident] ?? []
            for entry in contents.subtracting(groups[ident]?.includes ?? []).sorted() {
                result.addDomain(ident, entry,
                    command: "object-group fqdn \(ident) include \(entry)")
            }
            result.expectedGroupContents[ident] = contents
            result.exactRouteChains[ident] = chain
        }
        reservedIDs = allocated
        if !result.createdGroups.isEmpty {
            result.notes.append("Новые части получают ту же цепочку маршрутов; в каждой не больше \(limit) записей.")
        }
        let emptied = managed.filter { !$0.includes.isEmpty && targets[$0.ident]?.isEmpty == true }
        if !emptied.isEmpty {
            result.notes.append("Освободившиеся части сохранены с маршрутами для будущих обновлений: \(emptied.count).")
        }
        result.sourceVersions = [OperationSourceVersion(spec: data.spec, data: data)]
        return result
    }

    private static func safeToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !value.contains(where: { "!;|$<>\"'\\".contains($0) })
    }

    /// Общий parser допускает неизвестные CLI-флаги для отображения. При
    /// копировании цепочки неизвестный флаг нельзя молча потерять.
    static func validatedRouteChain(_ group: FqdnGroup, sourceTitle: String) throws -> [DnsRouteAssignment] {
        var chain: [DnsRouteAssignment] = []
        var interfaces = Set<String>()
        for line in group.routeLines {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let flags = tokens.dropFirst(5).map { $0.lowercased() }
            guard tokens.count >= 5, tokens.prefix(3).elementsEqual(["dns-proxy", "route", "object-group"]),
                  tokens[3] == group.ident || tokens[3] == group.descriptionText,
                  safeToken(tokens[4]), interfaces.insert(tokens[4]).inserted,
                  Set(flags).isSubset(of: ["auto", "reject"]), Set(flags).count == flags.count,
                  let assignment = DnsRouteAssignment.parse(line) else {
                throw TransportError("\(sourceTitle): не удалось однозначно прочитать маршруты \(group.ident).",
                                     hint: "Проверь цепочку интерфейсов этого списка перед обновлением.")
            }
            chain.append(assignment)
        }
        return chain
    }
}
