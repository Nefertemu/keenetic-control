import SwiftUI

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
