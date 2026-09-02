import AppKit
import SwiftUI

/// Наблюдение за туннелями: связь, задержки, пиры и история.
///
/// Ничего не меняет на роутере. Замена конфигурации живёт отдельно
/// (`TunnelUpdateView`): держать «Безопасно обновить» в одной прокрутке
/// с живым графиком значило ставить необратимое действие туда, куда
/// заходят просто посмотреть.
struct TunnelStatusView: View {
    @EnvironmentObject private var session: RouterSession
    @Binding var alert: AlertPayload?
    /// Выбранный туннель принадлежит разделу: между вкладками он не
    /// должен сбрасываться.
    @Binding var interfaceIdent: String

    @State private var interfaceName = ""
    @State private var namePlan: Plan?
    @State private var pingRefreshing = false
    @State private var pingUpdatedAt: Date?
    @State private var pingError: String?
    @ObservedObject private var healthStore = TunnelHealthStore.shared
    @ObservedObject private var store = Store.shared

    private var interfaces: [String] { session.state?.wireguardInterfaces ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let progress = session.progress { ProgressBanner(info: progress) }

                if session.state == nil {
                    TunnelsEmptyState.notConnected
                } else if interfaces.isEmpty {
                    TunnelsEmptyState.noInterfaces
                } else {
                    interfaceCard
                    TunnelProbeView(alert: $alert)
                    TunnelAvailabilityMatrix(rows: availabilityRows, hours: 24)
                }
            }
            .padding(20)
        }
        .onAppear {
            pickDefault()
            if let wanted = Navigator.shared.takeInterface(), interfaces.contains(wanted) {
                interfaceIdent = wanted
            }
        }
        .onChange(of: session.state?.readAt) { _, _ in
            // Live Ping-Check обновляет readAt каждые несколько секунд. Не
            // сбрасываем из-за этого время последней проверки и её ошибку —
            // иначе UI всё время выглядит так, будто ответа ещё не было.
            if interfaceIdent.isEmpty || !interfaces.contains(interfaceIdent) {
                pickDefault()
            } else {
                syncInterfaceName()
            }
        }
        .onChange(of: interfaceIdent) { _, _ in
            syncInterfaceName()
            pingUpdatedAt = nil
            pingError = nil
        }
        .onChange(of: session.router.id) { _, _ in
            // Черновик имени относится к старому роутеру — не даём случайно
            // применить его после переключения.
            namePlan = nil
            interfaceName = ""
            pickDefault()
        }
        // Ping-Check и статистика WireGuard живут в статусе интерфейса, а не
        // в running-config. Обновляем их отдельно, пока открыт этот экран.
        .task(id: liveMonitorID) { await monitorLiveInterface() }
        .sheet(item: Binding(get: { namePlan.map(PlanBox.init) }, set: { namePlan = $0?.plan })) { box in
            PlanSheet(plan: box.plan, applyTitle: "Сохранить имя", state: session.state) { dryRun in
                namePlan = nil
                Task { await applyName(box.plan, dryRun: dryRun) }
            } onCancel: { namePlan = nil }
        }
    }

    private func pickDefault() {
        if interfaceIdent.isEmpty || !interfaces.contains(interfaceIdent) {
            interfaceIdent = interfaces.first ?? ""
        }
        syncInterfaceName()
    }


    private var peers: [WireGuardPeerState] {
        session.state?.interfaces[interfaceIdent]?.peers ?? []
    }


    private var liveState: WireGuardState? {
        guard let text = session.state?.configText, !interfaceIdent.isEmpty else { return nil }
        return WireGuardState.parse(config: text, interface: interfaceIdent)
    }


    private var liveMonitorID: String {
        let binding = session.state?.pingCheckBindings[interfaceIdent]?.profile ?? ""
        // Перезапускаем сторожа после смены роутера, интерфейса или профиля,
        // но не при кратком переходе online → offline во время восстановления
        // SSH: смена статуса иначе отменяет текущий запрос и тут же обрывает
        // только что поднятую сессию.
        return "\(session.router.id.uuidString)|\(interfaceIdent)|\(binding)"
    }




    private var currentPingCheck: PingCheckLiveState {
        session.state?.pingCheck(for: interfaceIdent) ?? .notConfigured
    }


    private var currentPingProfile: PingCheckProfile? {
        guard let name = session.state?.pingCheckBindings[interfaceIdent]?.profile,
              !name.isEmpty else { return nil }
        return session.state?.pingCheckProfiles.first { $0.name == name }
    }




    /// Доступность всех туннелей для общей шкалы.
    private var availabilityRows: [TunnelAvailabilityRow] {
        interfaces.enumerated().map { index, ident in
            TunnelAvailabilityRow(
                interface: ident,
                label: session.state?.shortLabel(for: ident) ?? ident,
                colorIndex: index,
                samples: healthStore.samples(routerID: session.router.id, interface: ident),
                availability: healthStore.availability(routerID: session.router.id,
                                                       interface: ident),
                outages: healthStore.outages(routerID: session.router.id, interface: ident))
        }
    }


    private func pingTint(_ state: PingCheckLiveState) -> Color {
        switch state {
        case .passing:       return Palette.success
        case .failing:       return Palette.danger
        case .notConfigured: return Palette.warning
        case .unknown:       return .secondary
        }
    }


    // MARK: - Живая проверка

    private var livePingCard: some View {
        let check = currentPingCheck
        let binding = session.state?.pingCheckBindings[interfaceIdent]
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    CardHeader(icon: "waveform.path.ecg",
                               title: "Встроенный Ping-Check",
                               subtitle: "Решение роутера: рабочий интерфейс или нет; RTT измеряется выше")
                    Spacer(minLength: 8)
                    livePingStatus(check)
                }
                .frame(minWidth: 700)

                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(icon: "waveform.path.ecg",
                               title: "Встроенный Ping-Check",
                               subtitle: "Статус роутера · автообновление каждые \(liveStatusSeconds) с")
                    livePingStatus(check)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let profile = currentPingProfile {
                    Text("Профиль: \(profile.name)")
                        .font(.system(size: 12, weight: .semibold))
                    Text(profile.target.isEmpty ? "цель скрыта роутером" : profile.target)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(profile.target)
                } else if let name = binding?.profile, !name.isEmpty {
                    Text("Профиль: \(name)")
                        .font(.system(size: 12, weight: .semibold))
                    Text("параметры не найдены в конфигурации")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("На интерфейс не назначен профиль Ping-Check")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await updateLiveInterface() }
                } label: {
                    Label("Проверить сейчас", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SubtleButtonStyle())
                .disabled(pingRefreshing || !session.status.isOnline)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    pingUpdatedLabel
                    Spacer(minLength: 0)
                    if check == .notConfigured {
                        configurePingButton
                    }
                    diagnosticsButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    pingUpdatedLabel
                    if check == .notConfigured { configurePingButton }
                    diagnosticsButton
                }
            }

            if let pingError {
                Text(pingError)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .inset()
    }


    private func livePingStatus(_ check: PingCheckLiveState) -> some View {
        StatusPill(text: check.title, tint: pingTint(check),
                   icon: check.isKnown ? (check == .passing ? "checkmark" : "xmark") : nil)
            .help(check.explanation)
    }


    @ViewBuilder
    private var pingUpdatedLabel: some View {
        if pingRefreshing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Проверяю интерфейс…")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        } else if let pingUpdatedAt {
            Text("Последняя проверка: \(pingUpdatedAt.formatted(date: .omitted, time: .standard)) · автообновление каждые \(liveStatusSeconds) с")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else {
            Text(session.status.isOnline ? "Ожидаю первый результат…" : "Подключись к роутеру, чтобы проверять интерфейс")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }


    private var configurePingButton: some View {
        Button("Настроить в Ping-Check") { Navigator.shared.tunnelsTab = .pingCheck }
            .buttonStyle(SubtleButtonStyle(tint: Palette.accent))
    }


    private var diagnosticsButton: some View {
        Button("Диагностика") { Navigator.shared.tunnelsTab = .diagnostics }
            .buttonStyle(SubtleButtonStyle(tint: Palette.accent))
    }


    // MARK: - Состояние интерфейса

    private var interfaceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    interfaceHeader
                    Spacer()
                    interfacePicker
                }
                .frame(minWidth: 540)

                VStack(alignment: .leading, spacing: 10) {
                    interfaceHeader
                    interfacePicker
                }
            }

            interfaceNameEditor

            livePingCard

            if let live = liveState {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    MetricTile(value: live.isUp ? "включён" : "выключен",
                               label: "Состояние", icon: "power",
                               tint: live.isUp ? Palette.success : Palette.warning)
                    MetricTile(value: String(live.peerKeys.count), label: "Пиров",
                               icon: "person.2", tint: live.peerKeys.count == 1 ? Palette.success : Palette.warning)
                    MetricTile(value: live.listenPort.isEmpty ? "—" : live.listenPort,
                               label: "ListenPort", icon: "number")
                    MetricTile(value: String(WireGuardService.routeCount(session.state?.configText ?? "")),
                               label: "Маршрутов у роутера", icon: "arrow.triangle.branch")
                }

                VStack(alignment: .leading, spacing: 7) {
                    if !live.addresses.isEmpty {
                        KeyValueRow(key: "Адрес интерфейса",
                                    value: live.addresses.joined(separator: ", "), monospaced: true)
                    }
                    if peers.isEmpty {
                        ForEach(live.peerKeys, id: \.self) { key in
                            KeyValueRow(key: "PublicKey пира", value: key, monospaced: true)
                        }
                    }
                }
                .padding(12)
                .inset()

                if !peers.isEmpty { peerTable }
            }

        }
        .card()
    }


    // MARK: - Настоящий RTT через каждый туннель




















    private var interfacePicker: some View {
        Picker("", selection: $interfaceIdent) {
            ForEach(interfaces, id: \.self) { ident in
                Text(session.state?.label(for: ident) ?? ident).tag(ident)
            }
        }
        .labelsHidden()
        .frame(minWidth: 180, idealWidth: 230, maxWidth: 280)
    }

    private var interfaceHeader: some View {
        CardHeader(icon: "shield.lefthalf.filled",
                   title: interfaceIdent.isEmpty
                     ? "WireGuard / AmneziaWG"
                     : (session.state?.shortLabel(for: interfaceIdent) ?? interfaceIdent),
                   subtitle: interfaceIdent.isEmpty
                     ? "Безопасное обновление с бэкапом и автоматическим откатом"
                     : "\(interfaceIdent) · безопасное обновление с бэкапом и откатом")
    }


    private var interfaceNameEditor: some View {
        let saved = session.state?.interfaces[interfaceIdent]?.descriptionText ?? ""
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                nameEditorField
                Spacer(minLength: 8)
                saveNameButton(saved: saved)
            }
            .frame(minWidth: 700)

            VStack(alignment: .leading, spacing: 10) {
                nameEditorField
                saveNameButton(saved: saved)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .inset()
    }


    private var nameEditorField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Имя интерфейса")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Например, Hetzner FIN", text: $interfaceName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            Text("Это подпись/description в Keenetic; WireguardN остаётся техническим идентификатором.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private func saveNameButton(saved: String) -> some View {
        Button("Сохранить имя") { buildNamePlan(current: saved) }
            .buttonStyle(SubtleButtonStyle())
            .disabled(interfaceIdent.isEmpty
                      || interfaceName.trimmingCharacters(in: .whitespacesAndNewlines) == saved
                      || session.progress != nil)
    }


    /// Пиры с живой статистикой: рукопожатие и трафик отличают рабочий
    /// туннель от повисшего, чего «включён» сам по себе не говорит.
    private var peerTable: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("Пир").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Точка входа").frame(width: 180, alignment: .leading)
                    Text("Рукопожатие").frame(width: 150, alignment: .leading)
                    Text("Принято").frame(width: 90, alignment: .trailing)
                    Text("Отдано").frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)

                Divider()

                ForEach(peers, id: \.publicKey) { peer in
                    peerRow(peer)
                    if peer.publicKey != peers.last?.publicKey { Divider() }
                }
            }
            .frame(minWidth: 760, alignment: .leading)
            .padding(.horizontal, 12)
        }
        .inset()
    }


    private func peerRow(_ peer: WireGuardPeerState) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(peer.isFresh ? Palette.success
                          : (peer.online ? Palette.warning : Color.secondary.opacity(0.4)))
                    .frame(width: 6, height: 6)
                Text(peer.publicKey.isEmpty ? "—" : peer.publicKey)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(peer.publicKey)

            Text(peer.endpoint.isEmpty ? "—" : peer.endpoint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(peer.endpoint.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)
                .help(peer.endpoint)

            Group {
                if !peer.online {
                    Text("не подключён").foregroundStyle(.tertiary)
                } else if let age = peer.handshakeAge {
                    Text(Format.ago(seconds: age))
                        .foregroundStyle(peer.isFresh ? Palette.success : Palette.warning)
                } else {
                    Text("не было").foregroundStyle(Palette.danger)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .frame(width: 150, alignment: .leading)

            Text(Format.bytes(peer.received))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(Format.bytes(peer.sent))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }


    // MARK: - Логика







    /// Как часто спрашивать роутер о живом статусе Ping-Check.
    ///
    /// По RCI это дешёвый GET — можно часто. По SSH каждая проверка поднимает
    /// ОТДЕЛЬНОЕ соединение с парольной аутентификацией (основной pty часть
    /// прошивок закрывает после `show ping-check`). Раз в четыре секунды это
    /// и лишняя нагрузка на роутер, и десятки логинов в минуту — ровно то,
    /// на что у веб-панели есть защита от подбора.
    private var liveStatusSeconds: Int {
        session.router.transport == .ssh ? 30 : 4
    }


    private func monitorLiveInterface() async {
        let ident = interfaceIdent
        guard !ident.isEmpty else { return }
        // Без привязки нет смысла ходить в роутер вообще: статус «проверки
        // нет» уже полностью описывает это состояние.
        guard session.state?.hasPingCheck(ident) == true else { return }
        while !Task.isCancelled {
            if session.status.isOnline, session.state != nil {
                await updateLiveInterface(ident: ident)
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(liveStatusSeconds) * 1_000_000_000)
            } catch {
                return
            }
        }
    }


    private func updateLiveInterface(ident: String? = nil) async {
        let target = ident ?? interfaceIdent
        guard !target.isEmpty,
              session.state?.hasPingCheck(target) == true,
              session.status.isOnline else { return }
        // Ручная кнопка и фоновый цикл используют один запрос: не запускаем
        // два `show interface` одновременно на одной CLI-очереди.
        guard !pingRefreshing else { return }
        pingRefreshing = true
        defer { pingRefreshing = false }

        do {
            let result = try await session.refreshLiveInterface(target)
            guard !Task.isCancelled, target == interfaceIdent else { return }
            if result == nil {
                pingError = "Роутер не вернул состояние интерфейса \(target)."
            } else {
                pingUpdatedAt = Date()
                pingError = nil
                if let result {
                    let configured = session.state?.hasPingCheck(target) == true
                    healthStore.record(routerID: session.router.id,
                                       interface: target,
                                       ping: result.pingCheck(configured: configured),
                                       interfaceUp: result.isUp,
                                       // Не каждая прошивка отдаёт возраст
                                       // рукопожатия в `show interface`. Его
                                       // отсутствие не должно превращать
                                       // успешный Ping-Check в «нестабильно»;
                                       // известный просроченный handshake всё
                                       // равно даст false.
                                       handshakeFresh: result.freshestHandshake.map { $0 <= 180 } ?? true,
                                       pingStatus: result.pingCheckStatus)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, target == interfaceIdent else { return }
            pingError = session.describe(error)
        }
    }


    private func syncInterfaceName() {
        guard !interfaceIdent.isEmpty else { interfaceName = ""; return }
        interfaceName = session.state?.interfaces[interfaceIdent]?.descriptionText ?? ""
    }


    private func buildNamePlan(current: String) {
        do {
            let built = try WireGuardPlanner.planRename(
                interface: interfaceIdent, current: current, desired: interfaceName)
            guard !built.isEmpty else {
                alert = AlertPayload(title: "Имя уже такое", message: "Изменений не требуется.", isError: false)
                return
            }
            namePlan = built.forRouter(session.router)
        } catch {
            alert = AlertPayload(title: "Имя не сохранено", message: session.describe(error))
        }
    }


    private func applyName(_ plan: Plan, dryRun: Bool) async {
        do {
            let outcome = try await session.apply(
                plan: plan, dryRun: dryRun, saveConfig: Store.shared.settings.saveConfigAfterApply)
            guard outcome.applied, !dryRun else { return }
            // `apply` owns and completes its own operation.  Reusing an
            // operation created before it would make the follow-up refresh
            // look stale and silently leave the old description in the form.
            _ = try? await session.refresh()
            syncInterfaceName()
        } catch {
            alert = AlertPayload(title: "Не удалось переименовать интерфейс",
                                 message: session.describe(error))
        }
    }
}
