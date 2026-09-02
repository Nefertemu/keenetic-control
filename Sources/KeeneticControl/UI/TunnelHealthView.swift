import SwiftUI

struct TunnelLatencySeries: Identifiable {
    var interface: String
    var label: String
    var colorIndex: Int
    var samples: [TunnelHealthSample]
    var id: String { interface }

    var latest: TunnelHealthSample? { samples.last }
    var latestLatency: Double? { latest?.latencyMS }
    var lossPercent: Double {
        let recent = samples.suffix(100)
        guard !recent.isEmpty else { return 0 }
        return recent.compactMap(\.lossPercent).reduce(0, +) / Double(recent.count)
    }
}

/// Один график для всех клиентских WireGuard-туннелей: теперь видно не
/// только факт доступности, но и какой маршрут отвечает быстрее или начал
/// заметно тормозить.
struct TunnelLatencyCard: View {
    let series: [TunnelLatencySeries]
    let target: String
    let refreshSeconds: Int

    private var hasData: Bool { series.contains { !$0.samples.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    header
                    Spacer(minLength: 10)
                    Text("обновление · \(refreshSeconds) с")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    header
                    Text("Обновление каждые \(refreshSeconds) с")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            if hasData {
                TunnelLatencyChart(series: series)
                    .frame(height: 150)
                    .padding(10)
                    .inset(cornerRadius: 10)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                    ForEach(series) { item in latencyLegend(item) }
                }
            } else {
                EmptyHint(icon: "chart.xyaxis.line",
                          title: "Пинги ещё не накопились",
                          message: "Первая точка появится после активной проверки туннелей выше.")
                    .padding(.vertical, 4)
            }
        }
        .padding(12)
        .inset()
    }

    private var header: some View {
        CardHeader(icon: "chart.xyaxis.line",
                   title: "Пинги туннелей",
                   subtitle: "Все VPN до \(target) · последние 24 часа")
    }

    private func latencyLegend(_ item: TunnelLatencySeries) -> some View {
        HStack(spacing: 8) {
            Circle().fill(chartColor(item.colorIndex)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(item.interface).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let latency = item.latestLatency {
                Text(String(format: "%.0f мс", latency))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(item.lossPercent > 0 ? Palette.warning : Palette.success)
            } else {
                Text(item.samples.isEmpty ? "нет данных" : "нет ответа")
                    .font(.system(size: 10)).foregroundStyle(Palette.danger)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .inset(cornerRadius: 8)
    }
}

struct TunnelLatencyChart: View {
    let series: [TunnelLatencySeries]

    private var visible: [TunnelLatencySeries] {
        series.map {
            var copy = $0
            if copy.samples.count > 600 {
                let stride = max(1, copy.samples.count / 600)
                copy.samples = copy.samples.enumerated().compactMap { index, sample in
                    index.isMultiple(of: stride) || index == copy.samples.count - 1 ? sample : nil
                }
            }
            return copy
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let values = visible
            let width = max(1, geometry.size.width)
            let height = max(1, geometry.size.height)
            let dated = values.flatMap(\.samples)
            let start = dated.map(\.timestamp).min() ?? Date()
            let end = max(dated.map(\.timestamp).max() ?? start, start.addingTimeInterval(1))
            let ceiling = max(25, dated.compactMap(\.latencyMS).max() ?? 25)

            ZStack {
                Path { path in
                    for fraction in [0.25, 0.5, 0.75] {
                        path.move(to: CGPoint(x: 0, y: height * fraction))
                        path.addLine(to: CGPoint(x: width, y: height * fraction))
                    }
                }
                .stroke(Palette.stroke.opacity(0.8),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                ForEach(values) { item in
                    Path { path in
                        var drawing = false
                        for sample in item.samples {
                            guard let latency = sample.latencyMS else {
                                drawing = false
                                continue
                            }
                            let x = CGFloat(sample.timestamp.timeIntervalSince(start)
                                            / end.timeIntervalSince(start)) * width
                            let y = height - CGFloat(min(1, latency / ceiling)) * (height - 8) - 4
                            if drawing { path.addLine(to: CGPoint(x: x, y: y)) }
                            else { path.move(to: CGPoint(x: x, y: y)); drawing = true }
                        }
                    }
                    .stroke(chartColor(item.colorIndex),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

private func chartColor(_ index: Int) -> Color {
    let colors: [Color] = [Palette.accent, Palette.success, Palette.warning,
                           .purple, .cyan, .pink, .orange]
    return colors[index % colors.count]
}

/// Карточка истории одной VPN-связи. Данные уже подготовлены хранилищем,
/// поэтому вьюха остаётся лёгкой и не запускает сетевые запросы сама.
struct TunnelHealthCard: View {
    let samples: [TunnelHealthSample]
    let outages: [TunnelOutageInterval]
    let availability: Double?
    let interface: String

    private var latest: TunnelHealthSample? { samples.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    header
                    Spacer(minLength: 8)
                    if let latest { statePill(latest.state) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    header
                    if let latest { statePill(latest.state) }
                }
            }

            if samples.isEmpty {
                EmptyHint(icon: "chart.xyaxis.line",
                          title: "История ещё не накопилась",
                          message: "Оставь Ping-Check включённым — график появится после первой проверки.")
                    .padding(.vertical, 4)
            } else {
                TunnelHealthSparkline(samples: samples)
                    .frame(height: 78)
                    .padding(10)
                    .inset(cornerRadius: 10)

                summary

                if !outages.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Последние обрывы")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(outages.suffix(3).reversed())) { outage in
                            outageRow(outage)
                        }
                    }
                    .padding(10)
                    .inset(cornerRadius: 10)
                }
            }
        }
        .padding(12)
        .inset()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("История здоровья туннеля \(interface)")
    }

    private var header: some View {
        CardHeader(icon: "chart.xyaxis.line",
                   title: "Здоровье туннеля",
                   subtitle: "Последние 24 часа · хранение 7 дней")
    }

    private func statePill(_ state: TunnelHealthState) -> some View {
        StatusPill(text: state.title, tint: tint(for: state),
                   icon: icon(for: state))
    }

    private var summary: some View {
        HStack(spacing: 8) {
            summaryItem(title: "Доступность",
                        value: availability.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                        tint: availabilityTint)
            summaryItem(title: "Обрывов", value: String(outages.count),
                        tint: outages.isEmpty ? Palette.success : Palette.warning)
            summaryItem(title: "Проверок", value: String(samples.count), tint: Palette.accent)
        }
    }

    private var availabilityTint: Color {
        guard let availability else { return .secondary }
        if availability >= 0.995 { return Palette.success }
        if availability >= 0.95 { return Palette.warning }
        return Palette.danger
    }

    private func summaryItem(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .inset(cornerRadius: 8)
    }

    private func outageRow(_ outage: TunnelOutageInterval) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint(for: outage.state)).frame(width: 6, height: 6)
            Text(Format.humanDate(outage.startedAt))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(outage.endedAt == nil ? "идёт · \(Format.duration(outage.duration))"
                                       : Format.duration(outage.duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(outage.endedAt == nil ? Palette.danger : .secondary)
                .lineLimit(1)
        }
    }

    private func tint(for state: TunnelHealthState) -> Color {
        switch state {
        case .healthy:  return Palette.success
        case .degraded: return Palette.warning
        case .offline:  return Palette.danger
        case .unknown:  return .secondary
        }
    }

    private func icon(for state: TunnelHealthState) -> String? {
        switch state {
        case .healthy:  return "checkmark"
        case .degraded: return "exclamationmark"
        case .offline:  return "xmark"
        case .unknown:  return nil
        }
    }
}

/// Минимальный график без Swift Charts: он работает на macOS 14 и не
/// заставляет экран тянуть тяжёлый графический компонент ради пары десятков
/// точек. Высота состояния отражает здоровье, цвет — причину.
struct TunnelHealthSparkline: View {
    let samples: [TunnelHealthSample]

    private var visible: [TunnelHealthSample] { Array(samples.suffix(180)) }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let height = max(1, geometry.size.height)
            let values = visible

            ZStack {
                Path { path in
                    for fraction in [0.2, 0.5, 0.8] {
                        let y = height * fraction
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                }
                .stroke(Palette.stroke.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                Path { path in
                    guard !values.isEmpty else { return }
                    for (index, sample) in values.enumerated() {
                        let point = CGPoint(x: x(index: index, count: values.count, width: width),
                                            y: y(state: sample.state, height: height))
                        if index == 0 { path.move(to: point) }
                        else { path.addLine(to: point) }
                    }
                }
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                            lineJoin: .round))

                ForEach(values) { sample in
                    let index = values.firstIndex(where: { $0.id == sample.id }) ?? 0
                    Circle()
                        .fill(tint(for: sample.state))
                        .frame(width: values.count > 100 ? 3 : 5,
                               height: values.count > 100 ? 3 : 5)
                        .position(x: x(index: index, count: values.count, width: width),
                                  y: y(state: sample.state, height: height))
                }
            }
        }
    }

    private func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return width / 2 }
        return CGFloat(index) / CGFloat(count - 1) * width
    }

    private func y(state: TunnelHealthState, height: CGFloat) -> CGFloat {
        switch state {
        case .healthy:  return height * 0.12
        case .unknown:  return height * 0.50
        case .degraded: return height * 0.75
        case .offline:  return height * 0.92
        }
    }

    private func tint(for state: TunnelHealthState) -> Color {
        switch state {
        case .healthy:  return Palette.success
        case .degraded: return Palette.warning
        case .offline:  return Palette.danger
        case .unknown:  return .secondary
        }
    }
}
