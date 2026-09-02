import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case wireguard
    case pingCheck
    case diagnostics
    case fqdn
    case dnsRoutes
    case staticRoutes
    case compare
    case backups
    case journal
    case routers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:      return "Обзор"
        case .wireguard:     return "WireGuard"
        case .pingCheck:     return "Ping-Check"
        case .diagnostics:   return "Диагностика"
        case .fqdn:          return "Списки FQDN"
        case .dnsRoutes:     return "Маршруты списков"
        case .staticRoutes:  return "Статические маршруты"
        case .compare:       return "Сравнение роутеров"
        case .backups:       return "Резервные копии"
        case .journal:       return "Журнал"
        case .routers:       return "Роутеры и настройки"
        }
    }

    var icon: String {
        switch self {
        case .overview:      return "square.grid.2x2"
        case .wireguard:     return "shield.lefthalf.filled"
        case .pingCheck:     return "waveform.path.ecg"
        case .diagnostics:   return "stethoscope"
        case .fqdn:          return "list.bullet.rectangle"
        case .dnsRoutes:     return "arrow.triangle.branch"
        case .staticRoutes:  return "point.topleft.down.to.point.bottomright.curvepath"
        case .compare:       return "arrow.left.arrow.right"
        case .backups:       return "clock.arrow.circlepath"
        case .journal:       return "text.alignleft"
        case .routers:       return "gearshape"
        }
    }

    var group: String {
        switch self {
        case .overview:                          return "Роутер"
        case .wireguard, .pingCheck, .diagnostics: return "Туннели"
        case .fqdn, .dnsRoutes, .staticRoutes, .compare:
                                                 return "Маршрутизация"
        case .backups, .journal, .routers:       return "Служебное"
        }
    }
}

struct RootView: View {
    @ObservedObject var session: RouterSession
    @ObservedObject private var store = Store.shared

    @ObservedObject private var updater = AutoUpdater.shared
    @State private var section: AppSection = .overview
    @State private var alert: AlertPayload?
    @State private var plan: Plan?
    @State private var outcome: ApplyOutcome?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 252, max: 320)
        } detail: {
            detail
        }
        .environmentObject(session)
        .background(Palette.canvas)
        .alert(item: $alert) { payload in
            Alert(title: Text(payload.title),
                  message: Text(payload.message),
                  dismissButton: .default(Text("Понятно")))
        }
        .sheet(item: Binding(get: { plan.map(PlanBox.init) }, set: { plan = $0?.plan })) { box in
            PlanSheet(plan: box.plan, applyTitle: "Загрузить на роутер") { dryRun in
                plan = nil
                Task { await apply(box.plan, dryRun: dryRun) }
            } onCancel: { plan = nil }
        }
        .sheet(item: Binding(get: { outcome.map(OutcomeBox.init) }, set: { outcome = $0?.outcome })) { box in
            OutcomeSheet(title: "Обновление списков", outcome: box.outcome) { outcome = nil }
        }
        .task {
            AppDelegate.session = session
            AutoUpdater.shared.attach(session: session)
            if let router = store.selectedRouter { await session.switchTo(router) }

            let migration = await Task.detached(priority: .utility) {
                Backups.migrateLegacyBackups()
            }.value
            if migration.migrated > 0 {
                log(.ok, "Старые резервные копии зашифрованы: \(migration.migrated).")
            }
            if !migration.failures.isEmpty {
                log(.warn, "Не удалось зашифровать старые копии: "
                    + migration.failures.joined(separator: "; "))
            }
        }
        .task {
            await session.monitorConnections()
        }
    }

    // MARK: - Боковая панель

    private var sidebar: some View {
        VStack(spacing: 0) {
            routerCard
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            List(selection: $section) {
                ForEach(groups, id: \.self) { group in
                    Section(group) {
                        ForEach(AppSection.allCases.filter { $0.group == group }) { item in
                            Label(item.title, systemImage: item.icon)
                                .tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            footer
        }
        .background(.ultraThinMaterial)
    }

    private var groups: [String] {
        var seen: [String] = []
        for item in AppSection.allCases where !seen.contains(item.group) { seen.append(item.group) }
        return seen
    }

    /// Карточка роутера. Раньше вся карточка была одним Menu — borderlessButton
    /// схлопывал её до размера первой строки, адрес пропадал, а клик попадал
    /// мимо. Теперь карточка обычная, а выбор роутера — на отдельной кнопке.
    private var routerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(session.status.tint.opacity(0.16))
                        .frame(width: 32, height: 32)
                    Image(systemName: "wifi.router.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(session.status.tint)
                }

                Text(session.router.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 2)
            }

            if store.routers.count > 1 { routerTabs }

            // Адрес занимает всю ширину карточки: рядом с иконкой ему тесно,
            // и он резался посередине.
            Text(session.router.endpoint)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(session.router.endpoint)

            HStack(spacing: 8) {
                StatusPill(text: session.status.title,
                           tint: session.status.tint,
                           icon: session.status.isOnline ? "bolt.fill" : nil)

                Spacer(minLength: 0)

                Button {
                    Task { await toggleConnection(session.router) }
                } label: {
                    Image(systemName: session.status.isOnline ? "eject.circle" : "bolt.circle")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(session.status.isOnline ? Color.secondary : Palette.accent)
                .help(session.status.isOnline ? "Отключиться" : "Подключиться")
                .disabled(session.status.isBusy)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inset(cornerRadius: 11)
    }

    /// Вертикальные вкладки вместо скрытого меню со стрелкой. Каждая вкладка
    /// получает всю ширину карточки — имена роутеров не обрезаются справа,
    /// как это происходило у горизонтального списка.
    private var routerTabs: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 5) {
                ForEach(store.routers) { router in
                    let active = router.id == session.router.id
                    let routerStatus = session.connectionStatus(for: router.id)
                    HStack(spacing: 4) {
                        Button {
                            store.selectedRouterID = router.id
                            Task { await session.switchTo(router) }
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(routerStatus.tint)
                                    .frame(width: 6, height: 6)
                                Text(router.name)
                                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .foregroundStyle(active ? Palette.accent : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        routerConnectionButton(router, status: routerStatus)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? Palette.accent.opacity(0.14) : Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(active ? Palette.accent.opacity(0.45) : Palette.stroke, lineWidth: 1))
                    .help(router.endpoint)
                }
            }
            .padding(.vertical, 1)
        }
        // maxHeight позволял ScrollView ужаться до одной-двух строк при
        // перерасчёте sidebar. Фиксируем фактическую высоту до пяти строк:
        // три сохранённых роутера всегда видны целиком, дальше появляется
        // вертикальная прокрутка.
        .frame(height: CGFloat(min(store.routers.count, 5) * 37 - 3 + 2))
    }

    private func routerConnectionButton(_ router: RouterProfile,
                                        status: ConnectionStatus) -> some View {
        Group {
            if status.isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 20, height: 20)
            } else {
                Button {
                    Task { await toggleConnection(router) }
                } label: {
                    Image(systemName: status.isOnline ? "eject.circle" : "bolt.circle")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(status.isOnline ? Color.secondary : Palette.accent)
                .help(status.isOnline
                      ? "Отключить \(router.name)"
                      : "Подключить и прочитать \(router.name)")
                .accessibilityLabel(status.isOnline
                                    ? "Отключить \(router.name)"
                                    : "Подключить и прочитать \(router.name)")
            }
        }
        .frame(width: 22, height: 22)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let progress = session.progress {
                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.label)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(Palette.accent)
                }
                .padding(.horizontal, 12)
            } else if let activity = session.activity {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(activity).font(.system(size: 10)).lineLimit(1)
                }
                .padding(.horizontal, 12)
            }

            Text("Keenetic Control \(Bundle.appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }

    // MARK: - Содержимое

    @ViewBuilder
    private var detail: some View {
        ZStack(alignment: .top) {
            Palette.canvas.ignoresSafeArea()

            Group {
                switch section {
                case .overview:      OverviewView(alert: $alert, section: $section)
                case .wireguard:     WireGuardView(alert: $alert, section: $section)
                case .pingCheck:     PingCheckView(alert: $alert)
                case .diagnostics:   DiagnosticsView(alert: $alert)
                case .fqdn:          FqdnView(alert: $alert)
                case .dnsRoutes:     DnsRoutesView(alert: $alert)
                case .staticRoutes:  StaticRoutesView(alert: $alert)
                case .compare:       CompareView(alert: $alert, section: $section)
                case .backups:       BackupsView(alert: $alert)
                case .journal:       JournalView()
                case .routers:       RoutersView(alert: $alert)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let found = updater.finding { updateBanner(found) }
        }
        .navigationTitle(section.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                .disabled(session.progress != nil || session.status.isBusy)
                .keyboardShortcut("r", modifiers: .command)
                .help("Перечитать конфигурацию роутера (⌘R)")
            }
        }
    }

    /// Фоновая сверка что-то нашла. Полоса поверх содержимого, а не
    /// уведомление в никуда: план уже собран, его можно посмотреть сразу.
    private func updateBanner(_ found: AutoUpdater.Finding) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Источники разошлись с «\(found.routerName)»")
                    .font(.system(size: 12, weight: .semibold))
                Text(found.plan.summary.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if found.routerID == session.router.id {
                Button("Посмотреть план") { plan = found.plan }
                    .buttonStyle(PrimaryButtonStyle(tint: Palette.warning))
            } else {
                Text("проверялся другой роутер")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Button {
                updater.dismissFinding()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Скрыть до следующей проверки")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Palette.warning.opacity(0.5), lineWidth: 1)
            .allowsHitTesting(false))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Действия

    private func apply(_ plan: Plan, dryRun: Bool) async {
        do {
            let result = try await session.apply(plan: plan, dryRun: dryRun,
                                                 saveConfig: store.settings.saveConfigAfterApply)
            if result.applied {
                outcome = result
                updater.dismissFinding()
            }
        } catch {
            alert = AlertPayload(title: "Не удалось применить", message: session.describe(error))
        }
    }

    private func toggleConnection(_ profile: RouterProfile) async {
        let status = session.connectionStatus(for: profile.id)
        if status.isOnline {
            await session.disconnect(profile.id)
            return
        }
        do {
            _ = try await session.connectAndRefresh(profile)
        } catch {
            alert = AlertPayload(title: "Не удалось подключиться",
                                 message: "\(profile.name): \(session.describe(error))")
        }
    }

    private func refresh() async {
        let operation = session.beginOperation()
        do { try await session.refresh(operation: operation) }
        catch {
            guard session.activeRouterID == operation.routerID else { return }
            alert = AlertPayload(title: "Не удалось прочитать конфигурацию",
                                 message: session.describe(error))
        }
    }
}

extension Bundle {
    static var appVersion: String {
        (main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1.0"
    }
}
