import Foundation

/// Возврат к состоянию из резервной копии.
///
/// Приложение отвечает только за то, чем управляет само: списки FQDN, их
/// маршруты через dns-proxy и статические маршруты. Wi-Fi, NAT, межсетевой
/// экран и всё остальное из копии НЕ трогаются — иначе «откат» мог бы
/// снести настройки, которые к делу не относятся.
enum Restore {

    struct Selection {
        /// nil — все списки, пустое множество — ни одного.
        var groupIDs: Set<String>? = nil
        var restoreContents = true
        var restoreChains = true
        var restoreStaticRoutes = true
    }

    /// Чем текущая конфигурация отличается от снимка.
    struct Difference: Identifiable {
        /// Сверка показывается в sheet. Идентификатор должен переживать
        /// перерисовку, иначе SwiftUI воспринимает тот же результат как новый.
        let id = UUID()
        /// Домены, появившиеся после снимка, — их надо убрать.
        var snapshotGroups: [String: FqdnGroup] = [:]
        var currentGroups: [String: FqdnGroup] = [:]
        var snapshotStaticRoutes: [StaticRoute] = []
        var currentStaticRoutes: [StaticRoute] = []
        var changedDescriptions: [String: String] = [:]
        var extraDomains: [String: Set<String>] = [:]
        /// Домены, пропавшие после снимка, — их надо вернуть.
        var missingDomains: [String: Set<String>] = [:]
        /// Списки, которых в снимке не было, — удалить целиком.
        var extraGroups: [FqdnGroup] = []
        /// Списки, бывшие в снимке и исчезнувшие, — создать заново.
        var missingGroups: [FqdnGroup] = []
        /// Строки dns-proxy, которые нужно снять и вернуть при восстановлении.
        /// Здесь целые изменённые цепочки, включая неизменённые строки.
        var extraRouteLines: [String] = []
        var missingRouteLines: [String] = []
        /// У существующих маршрутов изменился относительный порядок.
        var reorderedRouteGroups: [String] = []
        /// Полные цепочки после восстановления: порядок интерфейсов задаёт
        /// приоритет резервирования и должен участвовать в проверке плана.
        var exactRouteChains: [String: [DnsRouteAssignment]] = [:]
        /// Статические маршруты.
        var extraRoutes: [StaticRoute] = []
        var missingRoutes: [StaticRoute] = []

        var extraDomainCount: Int { extraDomains.values.reduce(0) { $0 + $1.count } }
        var missingDomainCount: Int { missingDomains.values.reduce(0) { $0 + $1.count } }
        /// Реальные изменения между снимками, без временного снятия старых
        /// строк ради восстановления порядка. Нужны сводке RouterChange.
        var extraRouteCount: Int { Set(extraRouteLines).subtracting(missingRouteLines).count }
        var missingRouteCount: Int { Set(missingRouteLines).subtracting(extraRouteLines).count }

        var isEmpty: Bool {
            extraDomains.isEmpty && missingDomains.isEmpty
                && extraGroups.isEmpty && missingGroups.isEmpty
                && extraRouteLines.isEmpty && missingRouteLines.isEmpty
                && extraRoutes.isEmpty && missingRoutes.isEmpty && changedDescriptions.isEmpty
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
            if !changedDescriptions.isEmpty { parts.append("имён списков: \(changedDescriptions.count)") }
            return parts
        }
    }

    static func compare(backup: String, current: String) -> Difference {
        compare(groups: RouterConfigParser.parseFqdnGroups(CLI.normalizeNewlines(backup)),
                currentGroups: RouterConfigParser.parseFqdnGroups(CLI.normalizeNewlines(current)),
                staticRoutes: StaticRouteParser.parse(config: backup),
                currentStaticRoutes: StaticRouteParser.parse(config: current))
    }

    /// Точка входа для пользовательских файлов; compare также служит наблюдателю
    /// уже прочитанных конфигураций, поэтому сам не бросает ошибки.
    static func validatedComparison(backup: String, current: String) throws -> Difference {
        compare(backup: try ConfigurationText.validatedBackup(backup),
                current: try ConfigurationText.validatedBackup(current))
    }

    static func selecting(_ selection: Selection, from difference: Difference) -> Difference {
        let ids = selection.groupIDs ?? Set(difference.snapshotGroups.keys).union(difference.currentGroups.keys)
        var target = difference.currentGroups
        for ident in ids {
            let saved = difference.snapshotGroups[ident]
            if selection.restoreContents {
                target[ident] = saved
                if !selection.restoreChains, target[ident] != nil {
                    target[ident]?.routeLines = difference.currentGroups[ident]?.routeLines ?? []
                }
            } else if selection.restoreChains, target[ident] != nil {
                target[ident]?.routeLines = saved?.routeLines ?? []
            }
            // Ссылка по старому description перестанет разрешаться после
            // выборочного возврата имени. Сохраняем те же интерфейсы/флаги,
            // но такую ссылку переводим на стабильный идентификатор.
            if let group = target[ident] {
                target[ident]?.routeLines = group.routeLines.map { line in
                    var tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
                    if tokens.count >= 5, tokens[3] != ident, tokens[3] != group.descriptionText {
                        tokens[3] = ident
                        return tokens.joined(separator: " ")
                    }
                    return line
                }
            }
        }
        return compare(groups: target, currentGroups: difference.currentGroups,
                       staticRoutes: selection.restoreStaticRoutes ? difference.snapshotStaticRoutes : difference.currentStaticRoutes,
                       currentStaticRoutes: difference.currentStaticRoutes)
    }

    private static func compare(groups before: [String: FqdnGroup], currentGroups after: [String: FqdnGroup],
                                staticRoutes oldStatic: [StaticRoute], currentStaticRoutes newStatic: [StaticRoute]) -> Difference {
        var difference = Difference()
        difference.snapshotGroups = before
        difference.currentGroups = after
        difference.snapshotStaticRoutes = oldStatic
        difference.currentStaticRoutes = newStatic

        for ident in before.keys.sorted() {
            guard let old = before[ident] else { continue }
            guard let new = after[ident] else {
                difference.missingGroups.append(old)
                difference.exactRouteChains[ident] = old.routeAssignments
                continue
            }
            if old.descriptionText != new.descriptionText {
                difference.changedDescriptions[ident] = old.descriptionText
            }
            let gone = old.includes.subtracting(new.includes)
            let added = new.includes.subtracting(old.includes)
            if !gone.isEmpty { difference.missingDomains[ident] = gone }
            if !added.isEmpty { difference.extraDomains[ident] = added }
        }
        for ident in after.keys.sorted() where before[ident] == nil {
            if let new = after[ident] { difference.extraGroups.append(new) }
        }

        // Удаление/добавление только различающихся строк не восстанавливает
        // приоритет: недостающий первый маршрут оказался бы в конце цепочки.
        // Для изменённого списка снимаем цепочку целиком и возвращаем порядок
        // снимка. Неизменённые списки продолжают работать без перерыва.
        for ident in before.keys.sorted() {
            guard let old = before[ident], let new = after[ident],
                  old.routeLines != new.routeLines else { continue }
            difference.extraRouteLines.append(contentsOf: new.routeLines)
            difference.missingRouteLines.append(contentsOf: old.routeLines)
            difference.exactRouteChains[ident] = old.routeAssignments
            let common = Set(old.routeLines).intersection(new.routeLines)
            if old.routeLines.filter({ common.contains($0) }) != new.routeLines.filter({ common.contains($0) }) {
                difference.reorderedRouteGroups.append(ident)
            }
        }

        let oldKeys = Set(oldStatic.map(\.configurationKey))
        let newKeys = Set(newStatic.map(\.configurationKey))
        difference.missingRoutes = oldStatic.filter { !newKeys.contains($0.configurationKey) }
        difference.extraRoutes = newStatic.filter { !oldKeys.contains($0.configurationKey) }

        return difference
    }

    /// План возврата. Порядок важен: сначала убираем лишнее, потом
    /// восстанавливаем недостающее, маршруты — после самих списков.
    static func plan(_ difference: Difference, chunkSize: Int, title: String,
                     verificationLimit: Int = FqdnLimits.maximumEntries) -> Plan {
        var plan = Plan(title: title)
        plan.verifyBeforeSave = true
        let desiredRoutes = Set(difference.snapshotGroups.values.flatMap(\.routeLines).map(ConfigurationText.canonicalRouteLine))
        plan.expectedAbsentRouteLines = Set((difference.extraRouteLines + difference.extraGroups.flatMap(\.routeLines))
            .map(ConfigurationText.canonicalRouteLine)).subtracting(desiredRoutes)
        plan.groupEntryLimit = FqdnLimits.clamp(verificationLimit)
        let touched = Set(difference.extraDomains.keys).union(difference.missingDomains.keys)
            .union(difference.extraGroups.map(\.ident)).union(difference.missingGroups.map(\.ident))
            .union(difference.exactRouteChains.keys).union(difference.changedDescriptions.keys)
        plan.configurationBaselines = [ManagedConfigurationBaseline(
            groupIDs: touched, groups: difference.currentGroups.filter { touched.contains($0.key) },
            staticRoutes: difference.extraRoutes.isEmpty && difference.missingRoutes.isEmpty
                ? nil : Set(difference.currentStaticRoutes.map(\.configurationKey)))]
        for ident in touched {
            if let saved = difference.snapshotGroups[ident] {
                plan.expectedGroupContents[ident] = saved.includes
                plan.expectedDescriptions[ident] = saved.descriptionText
                plan.exactRouteChains[ident] = saved.routeAssignments
            } else { plan.expectedAbsentGroups.insert(ident) }
        }
        if !difference.extraRoutes.isEmpty || !difference.missingRoutes.isEmpty {
            plan.expectedStaticRoutes = Set(difference.snapshotStaticRoutes.map(\.configurationKey))
        }

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

        for (ident, description) in difference.changedDescriptions.sorted(by: { $0.key < $1.key }) {
            plan.commands.append(description.isEmpty
                ? "no object-group fqdn \(ident) description"
                : "object-group fqdn \(ident) description \(CLI.quote(description))")
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
        for route in difference.missingRoutes { plan.commands.append(contentsOf: route.additionCommands) }

        let notes = ["Возвращается только то, чем управляет приложение: списки FQDN, "
                     + "их маршруты и статические маршруты. Остальная конфигурация роутера "
                     + "остаётся как есть."]
        plan.notes = notes
        return plan
    }
    /// Нельзя молча менять идентификаторы исторического списка ради деления:
    /// другие части конфигурации могут ссылаться на него.
    static func validatedPlan(_ difference: Difference, chunkSize: Int, title: String,
                              verificationLimit: Int = FqdnLimits.maximumEntries) throws -> Plan {
        let result = plan(difference, chunkSize: chunkSize, title: title, verificationLimit: verificationLimit)
        let limit = result.groupEntryLimit ?? FqdnLimits.maximumEntries
        if let large = result.expectedGroupContents.first(where: { $0.value.count > limit }) {
            throw TransportError("В копии список \(large.key) содержит \(large.value.count) записей при лимите \(limit).",
                                 hint: "Выбери другие списки. Такой список нужно предварительно разделить.")
        }
        return result
    }

}
