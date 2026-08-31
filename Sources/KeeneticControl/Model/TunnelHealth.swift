import Combine
import Foundation

/// Состояние одной точки наблюдения туннеля. «Неизвестно» не считается
/// аварией: роутер иногда отдаёт статистику позже, чем ответ на интерфейс.
enum TunnelHealthState: String, Codable, Hashable {
    case healthy
    case degraded
    case offline
    case unknown

    var title: String {
        switch self {
        case .healthy:  return "в норме"
        case .degraded: return "нестабильно"
        case .offline:  return "интерфейс выключен"
        case .unknown:  return "нет данных"
        }
    }

    var isOutage: Bool { self == .degraded || self == .offline }
}

/// Небольшой снимок без конфигурации и секретов. История хранится локально,
/// чтобы график переживал переключение экранов и перезапуск приложения.
struct TunnelHealthSample: Codable, Hashable, Identifiable {
    var id: UUID
    var timestamp: Date
    var state: TunnelHealthState
    var interfaceUp: Bool
    var handshakeFresh: Bool
    var pingStatus: String?

    init(id: UUID = UUID(), timestamp: Date = Date(), state: TunnelHealthState,
         interfaceUp: Bool, handshakeFresh: Bool, pingStatus: String?) {
        self.id = id
        self.timestamp = timestamp
        self.state = state
        self.interfaceUp = interfaceUp
        self.handshakeFresh = handshakeFresh
        self.pingStatus = pingStatus
    }
}

/// Отрезок одной аварии. Он вычисляется из снимков и отдельно на диск не
/// пишется — так старые записи остаются компактными и легко обновляются.
struct TunnelOutageInterval: Hashable, Identifiable {
    var startedAt: Date
    var endedAt: Date?
    var state: TunnelHealthState

    var id: String { "\(startedAt.timeIntervalSince1970)-\(state.rawValue)" }
    var duration: TimeInterval {
        max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
    }
}

/// Локальная история здоровья туннелей. Запись ограничена одним снимком в
/// минуту для неизменного состояния, поэтому фоновая проверка раз в четыре
/// секунды не раздувает файл. Переходы состояния записываются сразу.
@MainActor
final class TunnelHealthStore: ObservableObject {
    static let shared = TunnelHealthStore()

    @Published private(set) var records: [String: [TunnelHealthSample]] = [:]

    private struct Snapshot: Codable {
        var records: [String: [TunnelHealthSample]]
    }

    private let fileURL: URL
    private let retention: TimeInterval = 7 * 24 * 60 * 60
    private let sameStateInterval: TimeInterval = 60
    private let maxSamplesPerTunnel = 10_000

    private init() {
        fileURL = AppPaths.support.appendingPathComponent("tunnel-health.json")
        load()
    }

    private func key(routerID: UUID, interface: String) -> String {
        "\(routerID.uuidString)|\(interface)"
    }

    /// Добавить наблюдение после успешного чтения живого состояния.
    func record(routerID: UUID, interface: String, ping: PingCheckLiveState,
                interfaceUp: Bool, handshakeFresh: Bool,
                pingStatus: String? = nil, now: Date = Date()) {
        guard !interface.isEmpty, ping != .notConfigured else { return }

        let state: TunnelHealthState
        if !interfaceUp {
            state = .offline
        } else {
            switch ping {
            case .passing:
                state = handshakeFresh ? .healthy : .degraded
            case .failing:
                state = .degraded
            case .unknown, .notConfigured:
                state = .unknown
            }
        }

        let recordKey = key(routerID: routerID, interface: interface)
        var samples = records[recordKey, default: []]
        if let last = samples.last,
           last.state == state,
           now.timeIntervalSince(last.timestamp) < sameStateInterval {
            return
        }

        samples.append(TunnelHealthSample(timestamp: now, state: state,
                                          interfaceUp: interfaceUp,
                                          handshakeFresh: handshakeFresh,
                                          pingStatus: pingStatus))
        trim(&samples, now: now)
        records[recordKey] = samples
        persist()
    }

    func samples(routerID: UUID, interface: String,
                  since: TimeInterval = 24 * 60 * 60,
                  now: Date = Date()) -> [TunnelHealthSample] {
        let cutoff = now.addingTimeInterval(-max(0, since))
        return (records[key(routerID: routerID, interface: interface)] ?? [])
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Сгруппировать подряд идущие плохие снимки в понятные человеку аварии.
    func outages(routerID: UUID, interface: String,
                 since: TimeInterval = 24 * 60 * 60,
                 now: Date = Date()) -> [TunnelOutageInterval] {
        let source = samples(routerID: routerID, interface: interface, since: since, now: now)
        guard !source.isEmpty else { return [] }

        var result: [TunnelOutageInterval] = []
        var current: TunnelOutageInterval?
        for sample in source {
            if sample.state.isOutage {
                if current == nil {
                    current = TunnelOutageInterval(startedAt: sample.timestamp,
                                                   endedAt: nil, state: sample.state)
                } else if current?.state != .offline, sample.state == .offline {
                    // Если за один отрезок сначала была деградация, а потом
                    // интерфейс совсем упал, показываем худшее состояние.
                    current?.state = .offline
                }
            } else if var open = current {
                open.endedAt = sample.timestamp
                result.append(open)
                current = nil
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// Доля здоровых наблюдений среди тех, где роутер ответил определённо.
    func availability(routerID: UUID, interface: String,
                      since: TimeInterval = 24 * 60 * 60,
                      now: Date = Date()) -> Double? {
        let observed = samples(routerID: routerID, interface: interface, since: since, now: now)
            .filter { $0.state != .unknown }
        guard !observed.isEmpty else { return nil }
        let healthy = observed.reduce(into: 0) { count, sample in
            if sample.state == .healthy { count += 1 }
        }
        return Double(healthy) / Double(observed.count)
    }

    private func trim(_ samples: inout [TunnelHealthSample], now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        samples.removeAll { $0.timestamp < cutoff }
        if samples.count > maxSamplesPerTunnel {
            samples.removeFirst(samples.count - maxSamplesPerTunnel)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = decodeSnapshot(data)
        else { return }

        var loaded = snapshot.records
        let now = Date()
        for key in Array(loaded.keys) {
            guard var samples = loaded[key] else { continue }
            trim(&samples, now: now)
            if samples.isEmpty { loaded.removeValue(forKey: key) }
            else { loaded[key] = samples.sorted { $0.timestamp < $1.timestamp } }
        }
        records = loaded
    }

    private func decodeSnapshot(_ data: Data) -> Snapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Snapshot(records: records)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
