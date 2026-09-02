import Foundation

/// Сохранённая последовательность интерфейсов для резервирования.
///
/// Одна и та же цепочка вида «Hetzner FIN → Hetzner DE → Infomaniak»
/// набиралась руками при каждом назначении. Профиль хранит её один раз.
/// Интерфейсы принадлежат конкретному роутеру — `Wireguard0` у соседа
/// значит другое, поэтому профиль привязан к нему.
struct FailoverProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var routerID: UUID
    var interfaces: [String] = []

    /// Какие интерфейсы профиля есть на роутере сейчас, а каких уже нет.
    func resolve(against available: [String]) -> (present: [String], missing: [String]) {
        var present: [String] = []
        var missing: [String] = []
        for ident in interfaces {
            if available.contains(ident) { present.append(ident) } else { missing.append(ident) }
        }
        return (present, missing)
    }

    static func validate(_ profile: FailoverProfile, existing: [FailoverProfile]) throws {
        let name = profile.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw TransportError("Дай профилю название.") }
        guard !profile.interfaces.isEmpty else {
            throw TransportError("В профиле нет ни одного интерфейса.",
                                 hint: "Собери порядок резервирования и сохрани его.")
        }
        // Совпадение имён на одном роутере путало бы список выбора.
        let clash = existing.contains {
            $0.id != profile.id && $0.routerID == profile.routerID
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        guard !clash else { throw TransportError("Профиль «\(name)» на этом роутере уже есть.") }
    }
}
