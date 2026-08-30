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
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                interfaces(state)
                                lists(state)
                            }
                            .frame(minWidth: 680)

                            VStack(alignment: .leading, spacing: 16) {
                                interfaces(state)
                                lists(state)
                            }
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
        // Пароль отвергнут — «Повторить» не поможет, а счётчик защиты роутера
        // подвинет. Ведём к настройкам, а не к новой попытке.
        let blocked = session.authBlock(session.router.id) != nil

        return VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: "exclamationmark.triangle.fill",
                       title: blocked ? "Роутер не принял пароль" : "Не удалось подключиться",
                       subtitle: session.router.endpoint, tint: Palette.danger)
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .inset()
            ViewThatFits(in: .horizontal) {
                HStack {
                    failureActions
                }
                .frame(minWidth: 500, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    failureActions
                }
            }
        }
        .card()
    }

    // MARK: - Содержимое

    private func metrics(_ state: RouterState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    metricsHeader(state)
                    Spacer()
                    StatusPill(text: session.status.title, tint: session.status.tint, icon: "bolt.fill")
                }
                .frame(minWidth: 560)

                VStack(alignment: .leading, spacing: 8) {
                    metricsHeader(state)
                    StatusPill(text: session.status.title, tint: session.status.tint, icon: "bolt.fill")
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                MetricTile(value: String(state.groups.count), label: "Списков FQDN",
                           icon: "list.bullet.rectangle")
                MetricTile(value: String(state.totalDomains), label: "Доменов в списках",
                           icon: "globe", tint: Palette.success)
                MetricTile(value: state.groups.isEmpty
                             ? "—" : "\(state.routedGroups) / \(state.groups.count)",
                           label: "С маршрутом",
                           icon: "arrow.triangle.branch",
                           tint: state.groups.isEmpty ? .secondary
                             : (state.routedGroups == state.groups.count ? Palette.success : Palette.warning))
                MetricTile(value: String(state.staticRoutes.count), label: "Статических маршрутов",
                           icon: "point.topleft.down.to.point.bottomright.curvepath")
            }
        }
        .card()
    }

    private func metricsHeader(_ state: RouterState) -> some View {
        CardHeader(icon: "wifi.router.fill", title: session.router.name,
                   subtitle: "Прочитано \(Format.age(state.readAt)) · \(session.router.endpoint)")
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
                            Text(item.shortName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            // Под именем — технический идентификатор и состояние:
                            // имя опознаёт человек, идентификатор нужен командам.
                            let details = (item.descriptionText.isEmpty
                                           ? [item.statusText]
                                           : [item.ident, item.statusText])
                                .filter { !$0.isEmpty }
                                .joined(separator: " · ")
                            if !details.isEmpty {
                                Text(details)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            // Живое состояние: проверка связи и рукопожатие.
                            // «включён» не отличает рабочий туннель от повисшего.
                            LiveStateLine(check: state.pingCheck(for: item.ident),
                                          handshake: item.freshestHandshake,
                                          online: item.isUp && !item.peers.isEmpty)
                        }
                        .help(item.displayName
                              + (item.statusText.isEmpty ? "" : "\n" + item.statusText))

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
            ViewThatFits(in: .horizontal) {
                HStack {
                    listsHeader(state)
                    Spacer()
                    Button("Все списки") { section = .dnsRoutes }
                        .buttonStyle(SubtleButtonStyle())
                }
                .frame(minWidth: 480)

                VStack(alignment: .leading, spacing: 8) {
                    listsHeader(state)
                    Button("Все списки") { section = .dnsRoutes }
                        .buttonStyle(SubtleButtonStyle())
                }
            }

            if state.groups.isEmpty {
                EmptyHint(icon: "tray", title: "Списков ещё нет",
                          message: "Зайди в «Списки FQDN» и залей первый источник.")
            } else {
                VStack(spacing: 0) {
                    let visible = Array(state.sortedGroups.prefix(9))
                    ForEach(visible) { group in
                        listRow(group, state: state)
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

    private func listsHeader(_ state: RouterState) -> some View {
        CardHeader(icon: "list.bullet.rectangle", title: "Списки FQDN",
                   subtitle: "\(Format.domains(state.totalDomains)) в \(Format.inLists(state.groups.count))")
    }

    @ViewBuilder
    private var failureActions: some View {
        if session.authBlock(session.router.id) != nil {
            Button("Впиши пароль в настройках") { section = .routers }
                .buttonStyle(PrimaryButtonStyle())
            Button("Всё равно попробовать") {
                session.clearAuthBlock(session.router.id)
                Task { await connect() }
            }
            .buttonStyle(SubtleButtonStyle(tint: Palette.danger))
            .help("Ещё одна неудачная попытка приближает отключение веб-панели "
                  + "роутера для этого компьютера на 15 минут")
        } else {
            Button("Повторить") { Task { await connect() } }
                .buttonStyle(PrimaryButtonStyle())
            Button("Настройки роутера") { section = .routers }
                .buttonStyle(SubtleButtonStyle())
        }
    }

    /// Строка списка. Маршруты стоят под именем и занимают всю ширину
    /// карточки: ярлык сбоку вмещал только один интерфейс, а их бывает
    /// несколько, и остальные молча пропадали.
    private func listRow(_ group: FqdnGroup, state: RouterState) -> some View {
        let targets = group.routedInterfaces

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(group.descriptionText.isEmpty ? group.ident : group.descriptionText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(String(group.count))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 5) {
                Text(group.ident)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(0)

                if targets.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Palette.warning)
                    Text("без маршрута")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.warning)
                        .layoutPriority(1)
                } else {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Text(state.targetSummary(targets))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.success)
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help(targets.isEmpty
              ? "\(group.ident): маршрут не назначен"
              : "\(group.ident) →\n" + state.targetTooltip(targets))
        .onTapGesture { section = .dnsRoutes }
    }

    private func connect() async {
        let operation = session.beginOperation()
        do {
            try await session.connect()
            guard session.isCurrent(operation),
                  session.activeRouterID == operation.routerID else { return }
            try await session.refresh(operation: operation)
        } catch {
            guard session.activeRouterID == operation.routerID else { return }
            alert = AlertPayload(title: "Не удалось подключиться", message: session.describe(error))
        }
    }
}
