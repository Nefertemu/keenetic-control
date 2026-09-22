import CryptoKit
import Foundation

/// Только сообщения и сохраняемые диагностические строки. Исходные URL
/// источников и запросов проходят отдельно и остаются неизменными.
enum DiagnosticPrivacy {
    private static let urlPattern = try! NSRegularExpression(pattern: #"(?i)\bhttps?://[^\s<>"']+"#)

    static func redact(_ text: String) -> String {
        var result = CLI.redactSecrets(text)
        let matches = urlPattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let address = String(result[range])
            guard var components = URLComponents(string: address), components.host != nil else {
                // Даже повреждённый URL может содержать credentials; не
                // возвращаем его исходную строку в диагностический файл.
                result.replaceSubrange(range, with: "[адрес скрыт]")
                continue
            }
            guard components.user != nil || components.password != nil
                    || components.query != nil || components.fragment != nil else { continue }
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            result.replaceSubrange(range, with: components.string ?? "[адрес скрыт]")
        }
        return result
    }
}

struct OperationSourceVersion: Codable, Hashable, Identifiable {
    var key: String
    var title: String
    var fetchedAt: Date?
    var fromCache: Bool
    var entryCount: Int
    var digest: String
    var locations: [String]
    var id: String { key }

    init(spec: SourceSpec, data: SourceData) {
        key = spec.key
        title = DiagnosticPrivacy.redact(spec.title)
        fetchedAt = data.fetchedAt
        fromCache = data.fromCache
        entryCount = Set(data.entries).count
        digest = SHA256.hash(data: Data(Set(data.entries).sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        locations = (spec.domainURLs + spec.rawSubnetURLs).map { address in
            guard var url = URLComponents(string: address), url.scheme != nil else {
                return (address as NSString).lastPathComponent
            }
            if url.scheme == "file" { return (url.path as NSString).lastPathComponent }
            url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
            return url.string ?? "Источник"
        }
    }
}

struct OperationHistoryRecord: Codable, Identifiable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case running, saved, temporary, needsAttention, failed, interrupted, unchanged, cancelled

        var title: String {
            switch self {
            case .running: return "Выполняется"
            case .saved: return "Сохранено на роутере"
            case .temporary: return "Применено временно"
            case .needsAttention: return "Требует проверки"
            case .failed: return "Не завершено"
            case .interrupted: return "Прервано при закрытии"
            case .unchanged: return "Изменений нет"
            case .cancelled: return "Отменено до записи"
            }
        }
        var hasIssue: Bool {
            [.temporary, .needsAttention, .failed, .interrupted, .cancelled].contains(self)
        }
    }

    struct Change: Codable, Identifiable, Equatable {
        var ident: String
        var title: String
        var added: [String]
        var removed: [String]
        var beforeCount: Int
        var afterCount: Int
        var routesBefore: [String]
        var routesAfter: [String]
        var isCreated: Bool
        var isDeleted: Bool
        var id: String { ident }
    }

    var id = UUID()
    var routerID: UUID
    var routerName: String
    var endpoint: String
    var title: String
    var startedAt = Date()
    var finishedAt: Date?
    var status: Status
    var commandCount: Int
    var commands: [String]
    var changes: [Change]
    var sources: [OperationSourceVersion]
    var problems: [String]
    var backupURL: URL?

    var addedCount: Int { changes.reduce(0) { $0 + $1.added.count } }
    var removedCount: Int { changes.reduce(0) { $0 + $1.removed.count } }
    var commandsTruncated: Bool { commands.count < commandCount }

    init(profile: RouterProfile, plan: Plan, configText: String, backupURL: URL?) {
        routerID = profile.id
        routerName = DiagnosticPrivacy.redact(profile.name)
        endpoint = DiagnosticPrivacy.redact(profile.endpoint)
        title = DiagnosticPrivacy.redact(plan.title)
        status = .running
        commandCount = plan.commands.count
        commands = plan.commands.prefix(2_000).map(DiagnosticPrivacy.redact)
        var state = RouterState(configText: configText)
        state.groups = RouterConfigParser.parseFqdnGroups(configText)
        state.interfaces = RouterConfigParser.parseConfigInterfaces(configText)
        changes = plan.changes(against: state).map { row in
            let before = state.groups[row.ident]?.routeAssignments ?? []
            let after: [DnsRouteAssignment]
            if row.isDeleted {
                after = []
            } else if let exact = plan.exactRouteChains[row.ident] {
                after = exact
            } else {
                var updated = before
                for target in plan.unrouteTargets where target.group == row.ident {
                    updated.removeAll { $0.interface == target.interface }
                }
                for target in plan.routeTargets where target.group == row.ident {
                    if let index = updated.firstIndex(where: { $0.interface == target.interface }) {
                        // Reassigning the same interface can change only flags.
                        // Keep its position and retain the change in history.
                        updated[index] = target.assignment
                    } else {
                        updated.append(target.assignment)
                    }
                }
                after = updated
            }
            return Change(ident: row.ident, title: row.title,
                   added: Array(plan.adds[row.ident] ?? []).sorted(),
                   removed: Array(row.isDeleted ? state.groups[row.ident]?.includes ?? []
                                  : plan.removes[row.ident] ?? []).sorted(),
                   beforeCount: row.domainsBefore, afterCount: row.domainsAfter,
                   routesBefore: before.map(Self.routeLabel), routesAfter: after.map(Self.routeLabel),
                   isCreated: row.isNew, isDeleted: row.isDeleted)
        }
        sources = plan.sourceVersions
        problems = []
        self.backupURL = backupURL
    }

    /// Keep the persisted [String] representation backward-compatible while
    /// making flag-only changes visible in the readable routing difference.
    private static func routeLabel(_ route: DnsRouteAssignment) -> String {
        ([route.interface] + [route.auto ? "auto" : nil, route.reject ? "reject" : nil].compactMap { $0 })
            .joined(separator: " · ")
    }

    /// В хранилище не попадает текст конфигурации и значения секретных команд.
    func redacted() -> Self {
        var copy = self
        copy.routerName = DiagnosticPrivacy.redact(routerName)
        copy.endpoint = DiagnosticPrivacy.redact(endpoint)
        copy.title = DiagnosticPrivacy.redact(title)
        copy.commands = commands.map(DiagnosticPrivacy.redact)
        copy.problems = problems.map(DiagnosticPrivacy.redact)
        copy.changes = changes.map { change in
            var value = change
            value.ident = DiagnosticPrivacy.redact(value.ident)
            value.title = DiagnosticPrivacy.redact(value.title)
            value.added = value.added.map(DiagnosticPrivacy.redact)
            value.removed = value.removed.map(DiagnosticPrivacy.redact)
            value.routesBefore = value.routesBefore.map(DiagnosticPrivacy.redact)
            value.routesAfter = value.routesAfter.map(DiagnosticPrivacy.redact)
            return value
        }
        copy.sources = sources.map { source in
            var value = source
            value.key = DiagnosticPrivacy.redact(value.key)
            value.title = DiagnosticPrivacy.redact(value.title)
            value.locations = value.locations.map(DiagnosticPrivacy.redact)
            return value
        }
        return copy
    }
}
