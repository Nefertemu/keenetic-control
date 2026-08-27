import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var session: RouterSession
    @Binding var alert: AlertPayload?
    @Binding var section: AppSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let progress = session.progress { ProgressBanner(info: progress) }

                switch session.status {
                case .online:
                    if let state = session.state {
                        metrics(state)
                        HStack(alignment: .top, spacing: 16) {
                            interfaces(state)
                            lists(state)
                        }
                    } else {
                        loading
                    }

                case .connecting:
                    loading

                case .failed(let message):
                    failure(message)

                case .offline:
                    offline
                }
            }
            .padding(20)
        }
    }

    // MARK: - Состояния

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(session.activity ?? "Читаю роутер…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .card()
    }

    private var offline: some View {
        VStack(spacing: 14) {
            EmptyHint(
                icon: "bolt.horizontal.circle",
                title: "Роутер «\(session.router.name)» не подключён",
                message: "Подключение открывается по требованию: SSH-сессия или сессия веб-панели "
                       + "живёт только пока с ней работают.")
            Button("Подключиться и прочитать конфигурацию") {
                Task { await connect() }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .card(padding: 24)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: "exclamationmark.triangle.fill", title: "Не удалось подключиться",
                       subtitle: session.router.endpoint, tint: Palette.danger)
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .inset()
            HStack {
                Button("Повторить") { Task { await connect() } }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Настройки роутера") { section = .routers }
                    .buttonStyle(SubtleButtonStyle())
            }
        }
        .card()
    }

    // MARK: - Содержимое

    private func metrics(_ state: RouterState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeader(icon: "wifi.router.fill", title: session.router.name,
                           subtitle: "Прочитано \(Format.age(state.readAt)) · \(session.router.endpoint)")
                Spacer()
                StatusPill(text: session.status.title, tint: session.status.tint, icon: "bolt.fill")
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                MetricTile(value: String(state.groups.count), label: "Списков FQDN",
                           icon: "list.bullet.rectangle")
                MetricTile(value: String(state.totalDomains), label: "Доменов в списках",
                           icon: "globe", tint: Palette.success)
                MetricTile(value: "\(state.routedGroups) / \(state.groups.count)", label: "С маршрутом",
                           icon: "arrow.triangle.branch",
                           tint: state.routedGroups == state.groups.count ? Palette.success : Palette.warning)
                MetricTile(value: String(state.staticRoutes.count), label: "Статических маршрутов",
                           icon: "point.topleft.down.to.point.bottomright.curvepath")
            }
        }
        .card()
    }

    private func interfaces(_ state: RouterState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "network", title: "Интерфейсы",
                       subtitle: "Сначала те, на которые есть смысл вешать маршруты")

            let visible = Array(state.candidates.prefix(9))
            VStack(spacing: 0) {
                ForEach(visible) { item in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(item.isUp ? Palette.success : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(item.ident).font(.system(size: 12, weight: .medium))
                                if !item.descriptionText.isEmpty {
                                    Text(item.descriptionText)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.accent)
                                        .lineLimit(1)
                                }
                            }
                            if !item.statusText.isEmpty {
                                Text(item.statusText)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .help(item.statusText)
                            }
                        }

                        Spacer(minLength: 8)

                        if item.isVPN {
                            StatusPill(text: "VPN", tint: Palette.accent)
                        } else if item.defaultGW == "yes" {
                            StatusPill(text: "шлюз", tint: Palette.warning)
                        }
                    }
                    .padding(.vertical, 7)

                    if item.id != visible.last?.id { Divider() }
                }

                if state.candidates.isEmpty {
                    Text("Интерфейсы не прочитались")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else if state.candidates.count > visible.count {
                    Divider()
                    Text("и ещё \(state.candidates.count - visible.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .inset()
        }
        .card()
    }

    private func lists(_ state: RouterState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeader(icon: "list.bullet.rectangle", title: "Списки FQDN",
                           subtitle: "\(Format.domains(state.totalDomains)) в \(Format.lists(state.groups.count))")
                Spacer()
                Button("Все списки") { section = .dnsRoutes }
                    .buttonStyle(SubtleButtonStyle())
            }

            if state.groups.isEmpty {
                EmptyHint(icon: "tray", title: "Списков ещё нет",
                          message: "Зайди в «Списки FQDN» и залей первый источник.")
            } else {
                VStack(spacing: 0) {
                    let visible = Array(state.sortedGroups.prefix(9))
                    ForEach(visible) { group in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.descriptionText.isEmpty ? group.ident : group.descriptionText)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .help(group.descriptionText.isEmpty ? group.ident : group.descriptionText)
                                Text(group.ident)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(String(group.count))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            // Список бывает направлен на несколько интерфейсов,
                            // а карточка узкая: собираем их в один ярлык,
                            // полные имена с примечаниями — в подсказке.
                            if group.routedInterfaces.isEmpty {
                                StatusPill(text: "без маршрута", tint: Palette.warning)
                            } else {
                                let targets = group.routedInterfaces
                                let extra = targets.count - 1
                                StatusPill(text: extra > 0 ? "\(targets[0]) +\(extra)" : targets[0],
                                           tint: Palette.success)
                                    .help(targets.map { state.label(for: $0) }
                                        .joined(separator: "\n"))
                            }
                        }
                        .padding(.vertical, 7)

                        if group.id != visible.last?.id { Divider() }
                    }

                    if state.groups.count > visible.count {
                        Divider()
                        Text("и ещё \(state.groups.count - visible.count) — на вкладке «Маршруты списков»")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 7)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .inset()
            }
        }
        .card()
    }

    private func connect() async {
        do {
            try await session.connect()
            try await session.refresh()
        } catch {
            alert = AlertPayload(title: "Не удалось подключиться", message: session.describe(error))
        }
    }
}
