import Foundation

/// Идентичность данных формы. Переименование не сбрасывает ввод, а другой
/// адрес у того же профиля уже означает другой роутер и другую конфигурацию.
struct RouterPresentationContext: Hashable {
    let routerID: UUID
    let connectionKey: String

    init(_ profile: RouterProfile) {
        routerID = profile.id
        connectionKey = profile.connectionKey
    }
}

/// Редактируемая цепочка не должна незаметно восстанавливаться после
/// обновления конфигурации или подменяться прежним интерфейсом фильтра.
struct FailoverInterfaceDraft {
    var selected = ""
    var order: [String] = []
    var pending = ""
    private var initialized = false

    mutating func select(_ ident: String) {
        selected = ident
        if order.count <= 1 { order = ident.isEmpty ? [] : [ident] }
    }

    mutating func reconcile(available: [String], preferred: String?) {
        let available = Set(available)
        let preferred = preferred.flatMap { available.contains($0) ? $0 : nil } ?? ""
        if !initialized, !available.isEmpty {
            initialized = true
            selected = preferred
            order = preferred.isEmpty ? [] : [preferred]
        } else {
            if !available.contains(selected) { selected = preferred }
            order.removeAll { !available.contains($0) }
        }
        if !available.contains(pending) || order.contains(pending) { pending = "" }
    }

    mutating func apply(_ interfaces: [String]) {
        initialized = true
        var seen: Set<String> = []
        order = interfaces.filter { !$0.isEmpty && seen.insert($0).inserted }
        selected = order.first ?? ""
        pending = ""
    }

    mutating func appendPending(available: [String]) {
        guard !pending.isEmpty, available.contains(pending), !order.contains(pending) else {
            pending = ""
            return
        }
        order.append(pending)
        pending = ""
    }
}
