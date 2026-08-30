import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WireGuardView: View {
    @EnvironmentObject private var session: RouterSession
    @Binding var alert: AlertPayload?
    @Binding var section: AppSection

    @State private var interfaceIdent = ""
    @State private var interfaceName = ""
    @State private var config: WireGuardConfig?
    @State private var parseError: String?
    @State private var dropTargeted = false
    @State private var hasBaseline = false
    @State private var confirmUpdate = false
    @State private var confirmRollback = false
    @State private var working = false
    @State private var result: WireGuardUpdateResult?
    @State private var namePlan: Plan?
    @State private var pingRefreshing = false
    @State private var pingUpdatedAt: Date?
    @State private var pingError: String?

    private var interfaces: [String] { session.state?.wireguardInterfaces ?? [] }

    private var peers: [WireGuardPeerState] {
        session.state?.interfaces[interfaceIdent]?.peers ?? []
    }

    private var liveState: WireGuardState? {
        guard let text = session.state?.configText, !interfaceIdent.isEmpty else { return nil }
        return WireGuardState.parse(config: text, interface: interfaceIdent)
    }

    private var liveMonitorID: String {
        let binding = session.state?.pingCheckBindings[interfaceIdent]?.profile ?? ""
        // Перезапускаем сторожа после назначения/снятия профиля, но не на
        // каждое обновление живой статистики (оно меняет readAt).
        return "\(session.router.id.uuidString)|\(interfaceIdent)|\(session.status.isOnline)|\(binding)"
    }

    private var currentPingCheck: PingCheckLiveState {
        session.state?.pingCheck(for: interfaceIdent) ?? .notConfigured
    }

    private var currentPingProfile: PingCheckProfile? {
        guard let name = session.state?.pingCheckBindings[interfaceIdent]?.profile,
              !name.isEmpty else { return nil }
        return session.state?.pingCheckProfiles.first { $0.name == name }
    }

    private func pingTint(_ state: PingCheckLiveState) -> Color {
        switch state {
        case .passing:       return Palette.success
        case .failing:       return Palette.danger
        case .notConfigured: return Palette.warning
        case .unknown:       return .secondary
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let progress = session.progress { ProgressBanner(info: progress) }

                if session.state == nil {
                    notConnected
                } else if interfaces.isEmpty {
                    noInterfaces
                } else {
                    interfaceCard
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            fileCard
                            actionsCard
                        }
                        .frame(minWidth: 660)

                        VStack(alignment: .leading, spacing: 16) {
                            fileCard
                            actionsCard
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear(perform: pickDefault)
        .onChange(of: session.state?.readAt) { _, _ in pickDefault() }
        .onChange(of: interfaceIdent) { _, _ in
            refreshBaseline()
            syncInterfaceName()
            pingUpdatedAt = nil
            pingError = nil
        }
        .onChange(of: session.router.id) { _, _ in
            // Конфиг и черновик имени относятся к старому роутеру — не даём
            // случайно применить их после переключения.
            config = nil
            namePlan = nil
            interfaceName = ""
            pickDefault()
        }
        // Ping-Check и статистика WireGuard живут в статусе интерфейса, а не
        // в running-config. Обновляем их отдельно, пока открыт этот экран.
        .task(id: liveMonitorID) {
            await monitorLiveInterface()
        }
        .confirmationDialog("Обновить «\(session.state?.shortLabel(for: interfaceIdent) ?? interfaceIdent)» новым конфигом?",
                            isPresented: $confirmUpdate, titleVisibility: .visible) {
            Button("Безопасно обновить") { Task { await update() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Перед изменением снимется резервная копия конфигурации. "
                 + "Если что-то пойдёт не так, приложение само вернёт rollback-базу.")
        }
        .confirmationDialog("Откатить «\(session.state?.shortLabel(for: interfaceIdent) ?? interfaceIdent)» на rollback-базу?",
                            isPresented: $confirmRollback, titleVisibility: .visible) {
            Button("Откатить", role: .destructive) { Task { await rollback() } }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(item: Binding(get: { result.map(WGResultBox.init) }, set: { result = $0?.value })) { box in
            WireGuardResultSheet(result: box.value) { result = nil }
        }
        .sheet(item: Binding(get: { namePlan.map(PlanBox.init) }, set: { namePlan = $0?.plan })) { box in
            PlanSheet(plan: box.plan, applyTitle: "Сохранить имя") { dryRun in
                namePlan = nil
                Task { await applyName(box.plan, dryRun: dryRun) }
            } onCancel: { namePlan = nil }
        }
    }

    // MARK: - Пустые состояния

    private var notConnected: some View {
        EmptyHint(icon: "bolt.horizontal.circle", title: "Роутер не прочитан",
                  message: "Подключись и нажми «Обновить» — здесь появятся WireGuard-интерфейсы.")
            .card(padding: 24)
    }

    private var noInterfaces: some View {
        EmptyHint(icon: "shield.slash", title: "WireGuard-интерфейсов нет",
                  message: "Создай интерфейс Wireguard в веб-панели Keenetic — "
                         + "приложение обновляет существующие, но не создаёт новые.")
            .card(padding: 24)
    }

    // MARK: - Живая проверка

    private var livePingCard: some View {
        let check = currentPingCheck
        let binding = session.state?.pingCheckBindings[interfaceIdent]
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    CardHeader(icon: "waveform.path.ecg",
                               title: "Ping-Check в реальном времени",
                               subtitle: "Состояние и WireGuard-статистика обновляются автоматически")
                    Spacer(minLength: 8)
                    livePingStatus(check)
                }
                .frame(minWidth: 700)

                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(icon: "waveform.path.ecg",
                               title: "Ping-Check в реальном времени",
                               subtitle: "Автообновление каждые 4 секунды")
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
                }
                VStack(alignment: .leading, spacing: 6) {
                    pingUpdatedLabel
                    if check == .notConfigured { configurePingButton }
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
            Text("Последняя проверка: \(pingUpdatedAt.formatted(date: .omitted, time: .standard)) · автообновление каждые 4 с")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else {
            Text(session.status.isOnline ? "Ожидаю первый результат…" : "Подключись к роутеру, чтобы проверять интерфейс")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var configurePingButton: some View {
        Button("Настроить в Ping-Check") { section = .pingCheck }
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

            HStack(spacing: 8) {
                if hasBaseline {
                    StatusPill(text: "Rollback-база готова", tint: Palette.success, icon: "checkmark")
                } else {
                    StatusPill(text: "Rollback-база НЕ задана", tint: Palette.danger, icon: "exclamationmark")
                }
                Text(hasBaseline
                     ? "Есть куда откатиться, если обновление не приживётся."
                     : "Загрузи ТЕКУЩИЙ рабочий .conf и нажми «Сделать rollback-базой» — без этого обновление заблокировано.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .card()
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

    private var interfacePicker: some View {
        Picker("", selection: $interfaceIdent) {
            ForEach(interfaces, id: \.self) { ident in
                Text(session.state?.label(for: ident) ?? ident).tag(ident)
            }
        }
        .labelsHidden()
        .frame(minWidth: 180, idealWidth: 230, maxWidth: 280)
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

    // MARK: - Файл конфигурации

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "doc.badge.arrow.up", title: "Конфигурация .conf",
                       subtitle: "Перетащи файл сюда или выбери вручную")

            VStack(spacing: 10) {
                Image(systemName: dropTargeted ? "arrow.down.doc.fill" : "doc.text")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(dropTargeted ? Palette.accent : Color.secondary.opacity(0.45))

                if let config {
                    Text(config.fileName.isEmpty ? "Конфигурация загружена" : config.fileName)
                        .font(.system(size: 12, weight: .semibold))
                    StatusPill(text: config.flavour, tint: Palette.accent)
                } else {
                    Text("Файл не выбран")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Поддерживаются WireGuard, AmneziaWG и AmneziaWG 2.0. "
                         + "Для безопасного обновления в файле должен быть один [Peer].")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Button("Выбрать .conf…") { pickFile() }
                    .buttonStyle(SubtleButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(dropTargeted ? Palette.accent.opacity(0.08) : Palette.inset))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(dropTargeted ? Palette.accent : Palette.stroke,
                              style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                loadDropped(providers)
            }

            if let parseError {
                Text(parseError)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let config {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(config.summaryRows.enumerated()), id: \.offset) { _, row in
                        KeyValueRow(key: row.0, value: row.1,
                                    monospaced: row.0.contains("Key") || row.0.contains("Allowed")
                                             || row.0.contains("Endpoint") || row.0.contains("Адрес"))
                    }
                }
                .padding(12)
                .inset()
            }
        }
        .card()
    }

    // MARK: - Действия

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "bolt.shield", title: "Операции", subtitle: "Порядок действий имеет значение")

            step(number: 1,
                 title: "Сделать rollback-базой",
                 text: "Один раз загрузи ТЕКУЩИЙ рабочий .conf интерфейса и нажми эту кнопку. "
                     + "Приложение запомнит его в связке ключей — это точка возврата.",
                 button: "Сделать rollback-базой",
                 tint: Palette.accent,
                 enabled: config != nil && !working) {
                guard let config else { return }
                WireGuardVault.saveBaseline(config.sourceText, router: session.router, interface: interfaceIdent)
                refreshBaseline()
                log(.ok, "Rollback-база для \(interfaceIdent) сохранена.")
            }

            Divider()

            step(number: 2,
                 title: "Безопасно обновить",
                 text: "Бэкап → новый пир без AllowedIPs → адреса и ключи → проверка → "
                     + "удаление старого пира → включение → сохранение. При осечке — автоматический откат.",
                 button: "Безопасно обновить",
                 tint: Palette.success,
                 enabled: config != nil && hasBaseline && !working && session.progress == nil) {
                confirmUpdate = true
            }

            Divider()

            step(number: 3,
                 title: "Откатить обновление",
                 text: "Возвращает интерфейс на сохранённую rollback-базу. Файл .conf для этого не нужен.",
                 button: "Откатить обновление",
                 tint: Palette.warning,
                 enabled: hasBaseline && !working && session.progress == nil) {
                confirmRollback = true
            }

            if hasBaseline {
                Divider()
                Button("Забыть rollback-базу") {
                    WireGuardVault.clearBaseline(router: session.router, interface: interfaceIdent)
                    refreshBaseline()
                }
                .buttonStyle(SubtleButtonStyle(tint: Palette.danger))
            }
        }
        .card()
    }

    private func step(number: Int, title: String, text: String, button: String,
                      tint: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(tint.opacity(0.15)).frame(width: 20, height: 20)
                    Text(String(number))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action)
                .buttonStyle(PrimaryButtonStyle(tint: tint))
                .disabled(!enabled)
        }
    }

    // MARK: - Логика

    private func monitorLiveInterface() async {
        let ident = interfaceIdent
        guard !ident.isEmpty else { return }
        // Без привязки нет смысла ходить в роутер каждые четыре секунды:
        // статус «проверки нет» уже полностью описывает это состояние.
        guard session.state?.hasPingCheck(ident) == true else { return }
        while !Task.isCancelled {
            if session.status.isOnline, session.state != nil {
                await updateLiveInterface(ident: ident)
            }
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
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
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, target == interfaceIdent else { return }
            pingError = session.describe(error)
        }
    }

    private func pickDefault() {
        if interfaceIdent.isEmpty || !interfaces.contains(interfaceIdent) {
            interfaceIdent = interfaces.first ?? ""
        }
        syncInterfaceName()
        refreshBaseline()
        pingUpdatedAt = nil
        pingError = nil
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

    private func refreshBaseline() {
        guard !interfaceIdent.isEmpty else { hasBaseline = false; return }
        let router = session.router
        let interface = interfaceIdent
        Task {
            let found = await Task.detached {
                WireGuardVault.hasBaseline(router: router, interface: interface)
            }.value
            guard interface == interfaceIdent else { return }
            hasBaseline = found
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .data]
        panel.message = "Выбери файл конфигурации WireGuard (.conf)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func loadDropped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { load(url) }
        }
        return true
    }

    private func load(_ url: URL) {
        parseError = nil
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            config = try WireGuardConfig.parse(text: text, fileName: url.lastPathComponent)
            log(.info, "Загружен конфиг \(url.lastPathComponent) (\(config?.flavour ?? "")).")
        } catch {
            config = nil
            parseError = (error as? TransportError)?.message ?? error.localizedDescription
        }
    }

    private func update() async {
        guard let config else { return }
        working = true
        defer { working = false }
        do {
            var outcome = try await WireGuardService.safeUpdate(
                session: session, interface: interfaceIdent, config: config)
            outcome.label = session.state?.label(for: interfaceIdent) ?? interfaceIdent
            result = outcome
            refreshBaseline()
        } catch {
            alert = AlertPayload(title: "Обновление не удалось", message: session.describe(error))
        }
    }

    private func rollback() async {
        working = true
        defer { working = false }
        do {
            try await WireGuardService.rollback(session: session, interface: interfaceIdent)
            alert = AlertPayload(title: "Откат выполнен",
                                 message: "Интерфейс \(interfaceIdent) вернулся на rollback-базу.",
                                 isError: false)
        } catch {
            alert = AlertPayload(title: "Откат не удался", message: session.describe(error))
        }
    }
}

struct WGResultBox: Identifiable {
    let id = UUID()
    let value: WireGuardUpdateResult
    init(_ value: WireGuardUpdateResult) { self.value = value }
}

struct WireGuardResultSheet: View {
    let result: WireGuardUpdateResult
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: result.warnings.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(result.warnings.isEmpty ? Palette.success : Palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.rolledBack ? "Откачено" : "Интерфейс обновлён")
                        .font(.system(size: 16, weight: .semibold))
                    Text(result.label.isEmpty ? result.interface : result.label)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 7) {
                KeyValueRow(key: "Маршрутов до", value: String(result.routesBefore))
                KeyValueRow(key: "Маршрутов после", value: String(result.routesAfter))
                if let backup = result.backupURL {
                    KeyValueRow(key: "Резервная копия", value: backup.lastPathComponent, monospaced: true)
                }
            }
            .padding(12)
            .inset()

            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Замечания").font(.system(size: 12, weight: .semibold))
                    ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                        Text("• " + warning)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .inset()
            }

            HStack {
                if let backup = result.backupURL {
                    Button("Показать бэкап") {
                        NSWorkspace.shared.activateFileViewerSelecting([backup])
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
                Spacer()
                Button("Закрыть", action: onClose)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 420, idealWidth: 560, maxWidth: 560)
        .background(Palette.surface)
    }
}
