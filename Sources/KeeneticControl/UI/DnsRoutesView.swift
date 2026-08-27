import SwiftUI

struct DnsRoutesView: View {
    @EnvironmentObject private var session: RouterSession
    @ObservedObject private var store = Store.shared
    @Binding var alert: AlertPayload?

    enum Filter: String, CaseIterable, Identifiable {
        case all, unrouted, routed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all:       return "Все списки"
            case .unrouted:  return "Без маршрута"
            case .routed:    return "С маршрутом"
            }
        }
    }

    @State private var selection: Set<String> = []
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var interfaceIdent = ""
    @State private var useAuto = Store.shared.settings.defaultAuto
    @State private var useReject = Store.shared.settings.defaultReject
    @State private var plan: Plan?
    @State private var outcome: ApplyOutcome?
    @State private var confirmDelete = false

    private var groups: [FqdnGroup] {
        guard let state = session.state else { return [] }
        return state.sortedGroups.filter { group in
            let matchesFilter: Bool
            switch filter {
            case .all:      matchesFilter = true
            case .unrouted: matchesFilter = group.routeLines.isEmpty
            case .routed:   matchesFilter = !group.routeLines.isEmpty
            }
            let matchesQuery = query.isEmpty
                || group.ident.localizedCaseInsensitiveContains(query)
                || group.descriptionText.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesQuery
        }
    }

    private var selectedGroups: [FqdnGroup] {
        groups.filter { selection.contains($0.ident) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let progress = session.progress { ProgressBanner(info: progress) }
            controls
            table
        }
        .padding(20)
        .onAppear(perform: pickDefaultInterface)
        .onChange(of: session.state?.readAt) { _, _ in pickDefaultInterface() }
        .sheet(item: Binding(get: { plan.map(PlanBox.init) }, set: { plan = $0?.plan })) { box in
            PlanSheet(plan: box.plan) { dryRun in
                plan = nil
                Task { await apply(box.plan, dryRun: dryRun) }
            } onCancel: { plan = nil }
        }
        .sheet(item: Binding(get: { outcome.map(OutcomeBox.init) }, set: { outcome = $0?.outcome })) { box in
            OutcomeSheet(title: "Маршруты списков", outcome: box.outcome) { outcome = nil }
        }
        .confirmationDialog("Удалить выбранные списки с роутера?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить \(Format.lists(selection.count))", role: .destructive) {
                plan = Planner.planDeleteGroups(selectedGroups)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Вместе со списками снимутся и их маршруты. Перед применением ты увидишь полный план.")
        }
    }

    // MARK: - Управление

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: "arrow.triangle.branch", title: "Маршруты списков FQDN",
                       subtitle: "dns-proxy направляет домены списка в нужный туннель")

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Интерфейс").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Picker("", selection: $interfaceIdent) {
                        Text("— выбери —").tag("")
                        ForEach(session.state?.candidates ?? []) { item in
                            Text(item.displayName + (item.isUp ? " ✓" : "")).tag(item.ident)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Флаги").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Toggle("auto", isOn: $useAuto)
                            .help("Маршрут поднимается вместе с интерфейсом")
                        Toggle("reject", isOn: $useReject)
                            .help("Не пускать трафик вовсе вместо перенаправления")
                    }
                    .toggleStyle(.checkbox)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    Text("Выбрано: \(selection.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Назначить") { buildRoutePlan() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(selection.isEmpty || interfaceIdent.isEmpty)

                        Button("Снять") { buildUnroutePlan() }
                            .buttonStyle(SubtleButtonStyle())
                            .disabled(selection.isEmpty || interfaceIdent.isEmpty)

                        Button("Удалить") { confirmDelete = true }
                            .buttonStyle(SubtleButtonStyle(tint: Palette.danger))
                            .disabled(selection.isEmpty)
                    }
                }
            }
        }
        .card()
    }

    // MARK: - Таблица

    private var table: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)

                TextField("Поиск по имени списка", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                Spacer()

                Button(selection.count == groups.count && !groups.isEmpty ? "Снять выделение" : "Выбрать всё") {
                    selection = (selection.count == groups.count && !groups.isEmpty)
                        ? []
                        : Set(groups.map(\.ident))
                }
                .buttonStyle(SubtleButtonStyle())
                .disabled(groups.isEmpty)
            }

            if session.state == nil {
                EmptyHint(icon: "bolt.horizontal.circle", title: "Роутер не прочитан",
                          message: "Подключись и нажми «Обновить» — списки появятся здесь.")
            } else if groups.isEmpty {
                EmptyHint(icon: "tray", title: "Ничего не нашлось",
                          message: "Поменяй фильтр или залей списки на вкладке «Списки FQDN».")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        headerRow
                        ForEach(groups) { group in
                            row(group)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .inset()
            }
        }
        .card()
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 18)
            Text("Список").frame(width: 220, alignment: .leading)
            Text("Идентификатор").frame(width: 130, alignment: .leading)
            Text("Записей").frame(width: 70, alignment: .trailing)
            Text("Маршрут").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
    }

    private func row(_ group: FqdnGroup) -> some View {
        let isSelected = selection.contains(group.ident)

        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Palette.accent : Color.secondary.opacity(0.45))
                .frame(width: 18)

            Text(group.descriptionText.isEmpty ? "—" : group.descriptionText)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)

            Text(group.ident)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)

            Text(String(group.count))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(group.count > store.settings.maxDomainsPerList ? Palette.danger : .primary)
                .frame(width: 70, alignment: .trailing)

            HStack(spacing: 5) {
                if group.routedInterfaces.isEmpty {
                    StatusPill(text: "нет маршрута", tint: Palette.warning)
                } else {
                    ForEach(group.routedInterfaces, id: \.self) { target in
                        StatusPill(text: session.state?.label(for: target) ?? target,
                                   tint: target == interfaceIdent ? Palette.success : Palette.accent)
                            .help(target)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selection.remove(group.ident) } else { selection.insert(group.ident) }
        }
    }

    // MARK: - Действия

    private func pickDefaultInterface() {
        guard interfaceIdent.isEmpty || !(session.state?.interfaces.keys.contains(interfaceIdent) ?? false) else { return }
        // По умолчанию — первый VPN-интерфейс: чаще всего маршруты нужны именно туда.
        interfaceIdent = session.state?.candidates.first(where: { $0.isVPN })?.ident
            ?? session.state?.candidates.first?.ident
            ?? ""
    }

    private func buildRoutePlan() {
        let built = Planner.planRoutes(groups: selectedGroups, interface: interfaceIdent,
                                       auto: useAuto, reject: useReject)
        if built.isEmpty {
            alert = AlertPayload(title: "Уже назначено",
                                 message: "Все выбранные списки уже направлены на \(interfaceIdent).",
                                 isError: false)
            return
        }
        plan = built
    }

    private func buildUnroutePlan() {
        let built = Planner.planUnroute(groups: selectedGroups, interface: interfaceIdent)
        if built.isEmpty {
            alert = AlertPayload(title: "Снимать нечего",
                                 message: "Ни один из выбранных списков не направлен на \(interfaceIdent).",
                                 isError: false)
            return
        }
        plan = built
    }

    private func apply(_ plan: Plan, dryRun: Bool) async {
        do {
            let result = try await session.apply(plan: plan, dryRun: dryRun,
                                                 saveConfig: store.settings.saveConfigAfterApply)
            if result.applied {
                outcome = result
                selection.removeAll()
            }
        } catch {
            alert = AlertPayload(title: "Не удалось применить", message: session.describe(error))
        }
    }
}
