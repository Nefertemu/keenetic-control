import SwiftUI

/// Активная проверка всех клиентских туннелей одной целью.
///
/// От выбранного на соседних карточках интерфейса не зависит: смысл именно
/// в том, чтобы сравнить туннели между собой — какой отвечает быстрее и
/// какой начал терять пакеты. Поэтому живёт отдельным экраном-карточкой со
/// своим состоянием и своим циклом опроса.
struct TunnelProbeView: View {
    @EnvironmentObject private var session: RouterSession
    @Binding var alert: AlertPayload?

    @State private var probeTarget = "1.1.1.1"
    @State private var probeMethod: InterfaceProbeMethod = .icmp
    @State private var probePort = "443"
    @State private var probeResults: [String: InterfacePingResult] = [:]
    @State private var probeRunning = false
    @State private var probeUpdatedAt: Date?
    @State private var probeError: String?
    @ObservedObject private var healthStore = TunnelHealthStore.shared
    @ObservedObject private var store = Store.shared

    private var interfaces: [String] { session.state?.wireguardInterfaces ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            interfacePingCard
            TunnelLatencyCard(series: latencySeries,
                              target: probeTarget,
                              refreshSeconds: probeRefreshSeconds)
        }
        .onChange(of: session.router.id) { _, _ in resetProbe() }
        .onChange(of: probeTarget) { _, _ in resetProbe() }
        .onChange(of: probeMethod) { _, method in
            probePort = method.usesPort ? String(method.defaultPort) : ""
            resetProbe()
        }
        .onChange(of: probePort) { _, _ in resetProbe() }
        .task(id: interfaceProbeMonitorID) { await monitorInterfacePings() }
    }

    private func resetProbe() {
        probeResults.removeAll()
        probeUpdatedAt = nil
        probeError = nil
    }

    private var interfacePingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    CardHeader(icon: "timer",
                               title: "Проверка через WireGuard-интерфейсы",
                               subtitle: probeMethod.explanation)
                    Spacer(minLength: 12)
                    probeControls
                }
                .frame(minWidth: 720)

                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(icon: "timer",
                               title: "Проверка через WireGuard-интерфейсы",
                               subtitle: probeMethod.explanation)
                    probeControls
                }
            }

            Divider()

            VStack(spacing: 0) {
                ForEach(Array(interfaces.enumerated()), id: \.element) { index, ident in
                    interfacePingRow(ident)
                    if index < interfaces.count - 1 { Divider() }
                }
            }
            .inset()

            HStack(spacing: 7) {
                if probeRunning {
                    ProgressView().controlSize(.small)
                    Text("Проверяю туннели по очереди…")
                } else if let probeUpdatedAt {
                    Text("Последний запуск: \(probeUpdatedAt.formatted(date: .omitted, time: .standard)) · автообновление каждые \(probeRefreshSeconds) с")
                } else {
                    Text("Ожидаю первый запуск…")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)

            if let probeError {
                Text(probeError)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .inset()
    }

    private var probeControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Picker("Метод", selection: $probeMethod) {
                    ForEach(InterfaceProbeMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 170)

                TextField("Домен или IP", text: $probeTarget)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 130, idealWidth: 190, maxWidth: 240)
                    .onSubmit { Task { await runInterfacePings() } }
                if probeMethod.usesPort {
                    TextField("Порт", text: $probePort)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 66)
                        .onSubmit { Task { await runInterfacePings() } }
                }
                Button {
                    Task { await runInterfacePings() }
                } label: {
                    Label("Проверить все", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SubtleButtonStyle(tint: Palette.accent))
                .disabled(probeRunning || !session.status.isOnline)

                Picker("Интервал", selection: $store.settings.wireGuardProbeIntervalSeconds) {
                    ForEach([3, 5, 10, 20, 30, 60, 120, 300], id: \.self) { seconds in
                        Text("каждые \(seconds) с").tag(seconds)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 122)
            }

            if probeMethod != .icmp {
                Text("Цель должна быть направлена через эти туннели — например, назначена им в «Маршрутах списков».")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func interfacePingRow(_ ident: String) -> some View {
        let result = probeResults[ident]
        let tint: Color = result.map { item in
            if item.error != nil || item.received == 0 { return Palette.danger }
            return item.lossPercent > 0 ? Palette.warning : Palette.success
        } ?? .secondary

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                pingInterfaceIdentity(ident, tint: tint)
                    .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                pingMetric(probeMethod == .tcp ? "TCP" : "Сейчас",
                           value: formatLatest(result), tint: tint)
                    .frame(width: 82, alignment: .leading)
                pingMetric("Среднее", value: formatRTT(result?.averageRTT), tint: tint)
                    .frame(width: 82, alignment: .leading)
                pingMetric("Мин / макс", value: formatRange(result), tint: tint)
                    .frame(width: 120, alignment: .leading)
                pingMetric("Потери", value: formatLoss(result), tint: tint)
                    .frame(width: 76, alignment: .leading)
            }
            .frame(minWidth: 650)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            VStack(alignment: .leading, spacing: 8) {
                pingInterfaceIdentity(ident, tint: tint)
                HStack(spacing: 18) {
                    pingMetric(probeMethod == .tcp ? "TCP" : "Сейчас",
                               value: formatLatest(result), tint: tint)
                    pingMetric("Среднее", value: formatRTT(result?.averageRTT), tint: tint)
                    pingMetric("Мин / макс", value: formatRange(result), tint: tint)
                    pingMetric("Потери", value: formatLoss(result), tint: tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private func pingInterfaceIdentity(_ ident: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.state?.shortLabel(for: ident) ?? ident)
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 5) {
                    Text(ident)
                    if let source = probeResults[ident]?.source, source != ident {
                        Text("→ \(source)")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                if let error = probeResults[ident]?.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.danger)
                        .lineLimit(2)
                }
            }
        }
    }

    private func pingMetric(_ title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(value == "—" ? Color.secondary : tint)
                .lineLimit(1)
        }
    }

    private func formatRTT(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 10 ? String(format: "%.1f мс", value) : String(format: "%.0f мс", value)
    }

    private func formatLatest(_ result: InterfacePingResult?) -> String {
        guard let result else { return "—" }
        if result.method == .tcp {
            guard result.isReachable else { return "нет" }
            return result.latestRTT.map(formatRTT) ?? "доступен"
        }
        return formatRTT(result.latestRTT)
    }

    private func formatRange(_ result: InterfacePingResult?) -> String {
        guard let minimum = result?.minimumRTT, let maximum = result?.maximumRTT else { return "—" }
        return "\(String(format: "%.0f", minimum)) / \(String(format: "%.0f", maximum)) мс"
    }

    private func formatLoss(_ result: InterfacePingResult?) -> String {
        guard let result else { return "—" }
        return String(format: "%.0f%%", result.lossPercent)
    }

    private func monitorInterfacePings() async {
        guard !interfaces.isEmpty else { return }
        while !Task.isCancelled {
            if session.status.isOnline, session.state != nil {
                await runInterfacePings()
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(probeRefreshSeconds) * 1_000_000_000)
            } catch {
                return
            }
        }
    }

    private func runInterfacePings() async {
        guard !probeRunning, session.status.isOnline else { return }
        let cleanTarget: String
        do {
            cleanTarget = try InterfacePingProbe.validate(
                interface: interfaces.first ?? "Wireguard0", target: probeTarget).1
        } catch {
            probeError = session.describe(error)
            return
        }

        let checkedPort: Int?
        if probeMethod.usesPort {
            guard let value = Int(probePort), (1...65535).contains(value) else {
                probeError = "Порт должен быть числом от 1 до 65535."
                return
            }
            checkedPort = value
        } else {
            checkedPort = nil
        }

        let owner = session.router.id
        let targets = interfaces
        probeRunning = true
        probeError = nil
        defer { probeRunning = false }

        for ident in targets {
            guard !Task.isCancelled, owner == session.router.id else { return }
            do {
                let result = try await session.ping(interface: ident, target: cleanTarget, count: 1,
                                                    method: probeMethod, port: checkedPort)
                guard !Task.isCancelled, owner == session.router.id,
                      cleanTarget == probeTarget.trimmingCharacters(in: .whitespacesAndNewlines)
                else { return }
                probeResults[ident] = result
                healthStore.record(routerID: owner, result: result)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, owner == session.router.id else { return }
                let failed = InterfacePingResult(
                    interface: ident, target: cleanTarget,
                    method: probeMethod, port: checkedPort, source: nil,
                    transmitted: 0, received: 0, rtt: [], checkedAt: Date(),
                    error: session.describe(error))
                probeResults[ident] = failed
                healthStore.record(routerID: owner, result: failed)
            }
        }
        probeUpdatedAt = Date()
    }

    private var probeRefreshSeconds: Int {
        min(300, max(3, store.settings.wireGuardProbeIntervalSeconds))
    }

    private var interfaceProbeMonitorID: String {
        "\(session.router.id.uuidString)|\(interfaces.joined(separator: ","))|\(probeMethod.rawValue)|\(probeRefreshSeconds)"
    }

    private var latencySeries: [TunnelLatencySeries] {
        interfaces.enumerated().map { index, ident in
            TunnelLatencySeries(interface: ident,
                                label: session.state?.shortLabel(for: ident) ?? ident,
                                colorIndex: index,
                                samples: healthStore.latencySamples(
                                    routerID: session.router.id, interface: ident))
        }
    }
}
