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
            case .unrouted:  return "Нет на интерфейсе"
            case .routed:    return "С маршрутом"
            }
        }
    }

    @State private var selection: Set<String> = []
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var interfaceIdent = ""
    /// Интерфейсы для резервирования — порядок массива равен порядку
    /// маршрутов в итоговом плане.
    @State private var interfaceOrder: [String] = []
    @State private var addInterfaceIdent = ""
    @State private var useAuto = Store.shared.settings.defaultAuto
    @State private var useReject = Store.shared.settings.defaultReject
    @State private var plan: Plan?
    @State private var outcome: ApplyOutcome?
    @State private var confirmDelete = false

    private let scrollTopID = "dns-routes-top"

    private var groups: [FqdnGroup] {
        guard let state = session.state else { return [] }
        return state.sortedGroups.filter { group in
            let matchesFilter: Bool
            switch filter {
            case .all:      matchesFilter = true
            case .unrouted:
                // «Без маршрута» означает отсутствие именно на выбранном
                // интерфейсе. Раньше список исчезал только когда у него не
                // было маршрутов вообще, что мешало строить резервирование.
                matchesFilter = interfaceIdent.isEmpty
                    ? group.routeLines.isEmpty
                    : !group.isRouted(to: interfaceIdent)
            case .routed:
                // Симметрично с «Нет на интерфейсе»: когда интерфейс выбран,
                // показываем только списки, у которых маршрут есть именно на
                // нём, а не любой маршрут на роутере.
                matchesFilter = interfaceIdent.isEmpty
                    ? !group.routeLines.isEmpty
                    : group.isRouted(to: interfaceIdent)
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let progress = session.progress { ProgressBanner(info: progress) }
                    controls
                    table
                }
                .padding(.top, 4)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(scrollTopID)
            }
            .onAppear {
                resetScrollPosition(proxy)
            }
            .onChange(of: session.router.id) { _, _ in
                resetScrollPosition(proxy)
            }
        }
        .onAppear {
            pickDefaultInterface()
            // Пришли сюда из палитры команд — сразу показываем нужный список.
            if let wanted = Navigator.shared.takeListQuery() { query = wanted }
        }
        .onChange(of: session.state?.readAt) { _, _ in pickDefaultInterface() }
        .onChange(of: interfaceIdent) { _, newIdent in
            // В обычном (одноинтерфейсном) сценарии выбор сверху остаётся
            // единственной целью. Когда в редакторе уже собрана цепочка из
            // нескольких интерфейсов, не переписываем её случайной сменой
            // фильтра.
            if interfaceOrder.count <= 1 {
                interfaceOrder = newIdent.isEmpty ? [] : [newIdent]
            }
        }
        .onChange(of: session.router.id) { _, _ in
            // Идентификаторы списков у роутеров свои: чужое выделение
            // здесь ничего не значит и только вводит в заблуждение.
            selection.removeAll()
            query = ""
            interfaceOrder.removeAll()
            addInterfaceIdent = ""
            pickDefaultInterface()
        }
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
            Button("Удалить \(Format.lists(selectedGroups.count))", role: .destructive) {
                plan = Planner.planDeleteGroups(selectedGroups).forRouter(session.router)
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

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) {
                    interfaceControl
                    flagsControl
                    Spacer()
                    routeActions
                }
                // Измеряем настоящую ширину всех кнопок. Старый minWidth
                // скрывал переполнение, и SwiftUI выбирал этот вариант даже
                // когда действия уже вылезали за правую границу карточки.
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .bottom, spacing: 18) {
                            interfaceControl
                            flagsControl
                            Spacer(minLength: 0)
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        VStack(alignment: .leading, spacing: 10) {
                            interfaceControl
                            flagsControl
                        }
                    }
                    routeActions
                }
            }

            Divider()
            failoverEditor
        }
        .card()
    }

    private var interfaceControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Показывать маршруты для")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Picker("", selection: $interfaceIdent) {
                Text("— выбери —").tag("")
                ForEach(session.state?.candidates ?? []) { item in
                    Text(item.displayName + (item.isUp ? " ✓" : "")).tag(item.ident)
                }
            }
            .labelsHidden()
            .frame(minWidth: 180, idealWidth: 240, maxWidth: 280)
        }
    }

    private var flagsControl: some View {
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
    }

    private var routeActions: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Выбрано: \(selectedGroups.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    assignRoutesButton
                    unrouteButton
                    deleteGroupsButton
                }
                .frame(minWidth: 390, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    assignRoutesButton
                    HStack(spacing: 8) {
                        unrouteButton
                        deleteGroupsButton
                    }
                }
            }
        }
    }

    private var assignRoutesButton: some View {
        Button("Назначить по порядку") { buildRoutePlan() }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selectedGroups.isEmpty || (interfaceOrder.isEmpty && interfaceIdent.isEmpty)
                      || session.progress != nil)
    }

    private var unrouteButton: some View {
        Button("Снять") { buildUnroutePlan() }
            .buttonStyle(SubtleButtonStyle())
            .disabled(selectedGroups.isEmpty || interfaceIdent.isEmpty
                      || session.progress != nil)
    }

    private var deleteGroupsButton: some View {
        Button("Удалить") { confirmDelete = true }
            .buttonStyle(SubtleButtonStyle(tint: Palette.danger))
            .disabled(selectedGroups.isEmpty || session.progress != nil)
    }

    /// Компактный редактор порядка резервирования. Up/Down намеренно явные:
    /// в таблице SwiftUI drag-and-drop легко промахнуться, а порядок здесь
    /// напрямую определяет поведение роутера при отказе первого туннеля.
    private var failoverEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    failoverTitle
                    Spacer()
                    failoverSummary
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 4) {
                    failoverTitle
                    failoverSummary
                }
            }

            if interfaceOrder.isEmpty {
                Text("Добавь один или несколько интерфейсов. Первый в списке будет основным, остальные — резервными.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(interfaceOrder.enumerated()), id: \.element) { index, ident in
                        HStack(spacing: 8) {
                            Text(String(index + 1))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(index == 0 ? Palette.accent : .secondary)
                                .frame(width: 22, alignment: .trailing)
                            Text(interfaceLabel(ident))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                moveInterface(at: index, by: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(index == 0 ? Color.secondary.opacity(0.35) : Palette.accent)
                            .disabled(index == 0)
                            .help("Поднять выше")
                            Button {
                                moveInterface(at: index, by: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(index == interfaceOrder.count - 1
                                              ? Color.secondary.opacity(0.35) : Palette.accent)
                            .disabled(index == interfaceOrder.count - 1)
                            .help("Опустить ниже")
                            Button {
                                interfaceOrder.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.danger)
                            .help("Убрать из порядка")
                        }
                        .padding(.vertical, 6)
                        if index < interfaceOrder.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .inset()
            }

            HStack(spacing: 8) {
                Picker("", selection: $addInterfaceIdent) {
                    Text("Добавить интерфейс…").tag("")
                    ForEach(availableInterfaces) { item in
                        Text(item.displayName).tag(item.ident)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 180, idealWidth: 280, maxWidth: 320)
                Button("Добавить") {
                    guard !addInterfaceIdent.isEmpty else { return }
                    interfaceOrder.append(addInterfaceIdent)
                    addInterfaceIdent = ""
                }
                .buttonStyle(SubtleButtonStyle())
                .disabled(addInterfaceIdent.isEmpty)
                Spacer()
            }
        }
    }

    private var failoverTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Порядок резервирования")
                .font(.system(size: 12, weight: .semibold))
            Text("(для кнопки «Назначить по порядку»)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var failoverSummary: some View {
        if !interfaceOrder.isEmpty {
            Text(interfaceOrder.map(interfaceShortLabel).joined(separator: " → "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.accent)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var availableInterfaces: [KeeneticInterface] {
        (session.state?.candidates ?? []).filter { !interfaceOrder.contains($0.ident) }
    }

    private func interfaceLabel(_ ident: String) -> String {
        session.state?.label(for: ident) ?? ident
    }

    private func interfaceShortLabel(_ ident: String) -> String {
        session.state?.shortLabel(for: ident) ?? ident
    }

    private func moveInterface(at index: Int, by offset: Int) {
        let target = index + offset
        guard interfaceOrder.indices.contains(index), interfaceOrder.indices.contains(target) else { return }
        interfaceOrder.swapAt(index, target)
    }

    private func resetScrollPosition(_ proxy: ScrollViewProxy) {
        // NavigationSplitView на macOS иногда переносит offset с предыдущей
        // длинной вкладки. После layout-pass возвращаем именно этот экран к
        // шапке, чтобы карточка не оказалась под системным toolbar.
        DispatchQueue.main.async {
            proxy.scrollTo(scrollTopID, anchor: .top)
        }
    }

    // MARK: - Таблица

    private var table: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    filterPicker
                    searchField
                    Spacer()
                    selectAllButton
                }
                // A segmented Picker can draw its labels slightly outside
                // the proposed width. Keep enough room for all three tabs so
                // the last label can never overlap the search field.
                .frame(minWidth: 820)

                VStack(alignment: .leading, spacing: 8) {
                    filterPicker
                    HStack(spacing: 10) {
                        searchField
                        Spacer(minLength: 0)
                        selectAllButton
                    }
                }
            }

            if session.state == nil {
                EmptyHint(icon: "bolt.horizontal.circle", title: "Роутер не прочитан",
                          message: "Подключись и нажми «Обновить» — списки появятся здесь.")
            } else if groups.isEmpty {
                EmptyHint(icon: "tray", title: "Ничего не нашлось",
                          message: "Поменяй фильтр или залей списки на вкладке «Списки FQDN».")
            } else {
                GeometryReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(spacing: 0) {
                            headerRow
                            ForEach(groups) { group in
                                row(group)
                                Divider()
                            }
                        }
                        // A two-axis ScrollView proposes an unbounded width;
                        // without an explicit viewport width SwiftUI centers
                        // the compact content and squeezes the route column.
                        // Fill the viewport first, while retaining a minimum
                        // width for genuinely narrow windows.
                        .frame(minWidth: max(720, proxy.size.width - 24),
                               alignment: .leading)
                        .padding(.horizontal, 12)
                    }
                    .inset()
                }
                // Таблица раньше забирала всю оставшуюся высоту окна даже
                // для одной строки. В результате единственный маршрут висел
                // посреди огромной пустой области. Высота теперь следует за
                // содержимым, а длинный список прокручивается внутри карточки.
                .frame(height: min(520, max(132, CGFloat(groups.count) * 48 + 62)))
            }
        }
        .card()
    }

    private var filterPicker: some View {
        // The native segmented Picker may paint a title outside its layout
        // proposal on macOS. A small fixed-width tab strip keeps every title
        // inside its own hit target, so it can never cover the search field.
        HStack(spacing: 0) {
            ForEach(Filter.allCases) { item in
                Button {
                    filter = item
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .frame(width: 126, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(filter == item ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(filter == item ? Palette.accent : Color.clear))
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 1)
                .allowsHitTesting(false))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var searchField: some View {
        TextField("Поиск по имени списка", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 170, idealWidth: 260, maxWidth: 320)
    }

    private var selectAllButton: some View {
        // Считаем именно по видимым спискам: под фильтром «Без маршрута»
        // счётчик выделенного мог совпасть с числом строк случайно.
        let visibleIdents = Set(groups.map(\.ident))
        let allPicked = !groups.isEmpty && visibleIdents.isSubset(of: selection)
        return Button(allPicked ? "Снять выделение" : "Выбрать всё") {
            selection = allPicked ? selection.subtracting(visibleIdents)
                                  : selection.union(visibleIdents)
        }
        .buttonStyle(SubtleButtonStyle())
        .disabled(groups.isEmpty)
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
                .help(group.descriptionText)

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
                    // Ярлык подписан именем интерфейса, а полное
                    // «Dataforest · Wireguard0» — в подсказке.
                    ForEach(group.routedInterfaces.prefix(3), id: \.self) { target in
                        StatusPill(text: session.state?.shortLabel(for: target) ?? target,
                                   tint: target == interfaceIdent ? Palette.success : Palette.accent)
                            .help(session.state?.label(for: target) ?? target)
                    }
                    if group.routedInterfaces.count > 3 {
                        StatusPill(text: "+\(group.routedInterfaces.count - 3)", tint: .secondary)
                            .help(session.state?.targetTooltip(group.routedInterfaces) ?? "")
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
        let candidates = session.state?.candidates ?? []
        if !interfaceIdent.isEmpty && candidates.contains(where: { $0.ident == interfaceIdent }) {
            interfaceOrder = interfaceOrder.filter { orderedIdent in
                candidates.contains { candidate in candidate.ident == orderedIdent }
            }
            if interfaceOrder.isEmpty { interfaceOrder = [interfaceIdent] }
            return
        }
        // По умолчанию — первый VPN-интерфейс: чаще всего маршруты нужны именно туда.
        interfaceIdent = candidates.first(where: { $0.isVPN })?.ident
            ?? candidates.first?.ident
            ?? ""
        interfaceOrder = interfaceIdent.isEmpty ? [] : [interfaceIdent]
        addInterfaceIdent = ""
    }

    private func buildRoutePlan() {
        let ordered = interfaceOrder.isEmpty && !interfaceIdent.isEmpty
            ? [interfaceIdent] : interfaceOrder
        let built = ordered.count <= 1
            ? Planner.planRoutes(groups: selectedGroups, interface: ordered.first ?? "",
                                 auto: useAuto, reject: useReject)
            : Planner.planRoutes(groups: selectedGroups, interfaces: ordered,
                                 auto: useAuto, reject: useReject)
        if built.isEmpty {
            alert = AlertPayload(title: "Уже назначено",
                                 message: "Все выбранные списки уже направлены на выбранные интерфейсы.",
                                 isError: false)
            return
        }
        plan = built.forRouter(session.router)
    }

    private func buildUnroutePlan() {
        let built = Planner.planUnroute(groups: selectedGroups, interface: interfaceIdent)
        if built.isEmpty {
            alert = AlertPayload(title: "Снимать нечего",
                                 message: "Ни один из выбранных списков не направлен на \(interfaceIdent).",
                                 isError: false)
            return
        }
        plan = built.forRouter(session.router)
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
