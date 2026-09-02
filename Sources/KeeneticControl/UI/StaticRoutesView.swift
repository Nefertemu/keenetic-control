import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StaticRoutesView: View {
    @EnvironmentObject private var session: RouterSession
    @ObservedObject private var store = Store.shared
    @Binding var alert: AlertPayload?

    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var showAdd = false
    @State private var plan: Plan?
    @State private var outcome: ApplyOutcome?
    @State private var importPreview: [StaticRoute] = []
    @State private var importSkipped: [String] = []
    @State private var showImport = false

    private var routes: [StaticRoute] {
        let all = session.state?.staticRoutes ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.searchText.contains(query.lowercased()) }
    }

    /// Выделение переживает смену поиска, поэтому действия и счётчики
    /// работают только по тому, что человек сейчас видит.
    private var selectedRoutes: [StaticRoute] {
        routes.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let progress = session.progress { ProgressBanner(info: progress) }
            toolbar
            table
        }
        .padding(20)
        .onChange(of: session.router.id) { _, _ in
            // Маршруты у роутеров разные — чужое выделение здесь ничего
            // не значит, а кнопка «Удалить выбранные» выглядела активной.
            selection.removeAll()
            query = ""
        }
        .sheet(isPresented: $showAdd) {
            RouteEditor(interfaces: session.state?.candidates ?? []) { route in
                showAdd = false
                var built = Plan(title: "Добавление маршрута")
                built.commands = [route.command]
                plan = built.forRouter(session.router)
            } onCancel: { showAdd = false }
        }
        .sheet(isPresented: $showImport) {
            ImportPreview(routes: importPreview, skipped: importSkipped) { accepted in
                showImport = false
                guard !accepted.isEmpty else { return }
                var built = Plan(title: "Импорт \(Format.routes(accepted.count))")
                built.commands = accepted.map(\.command)
                built.notes = ["Маршруты добавляются как есть. Существующие такие же строки роутер просто перезапишет."]
                plan = built.forRouter(session.router)
            } onCancel: { showImport = false }
        }
        .sheet(item: Binding(get: { plan.map(PlanBox.init) }, set: { plan = $0?.plan })) { box in
            PlanSheet(plan: box.plan, state: session.state) { dryRun in
                plan = nil
                Task { await apply(box.plan, dryRun: dryRun) }
            } onCancel: { plan = nil }
        }
        .sheet(item: Binding(get: { outcome.map(OutcomeBox.init) }, set: { outcome = $0?.outcome })) { box in
            OutcomeSheet(title: "Статические маршруты", outcome: box.outcome) { outcome = nil }
        }
    }

    // MARK: - Панель

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    routesHeader
                    Spacer()
                    selectionPill
                }
                .frame(minWidth: 520)

                VStack(alignment: .leading, spacing: 8) {
                    routesHeader
                    selectionPill
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    routeSearchField
                    primaryRouteActions
                    Spacer()
                    transferActions
                }
                .frame(minWidth: 760)

                VStack(alignment: .leading, spacing: 9) {
                    routeSearchField
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            primaryRouteActions
                            Spacer(minLength: 0)
                            transferActions
                        }
                        .frame(minWidth: 560)

                        VStack(alignment: .leading, spacing: 8) {
                            primaryRouteActions
                            transferActions
                        }
                    }
                }
            }
        }
        .card()
    }

    private var routesHeader: some View {
        CardHeader(icon: "point.topleft.down.to.point.bottomright.curvepath",
                   title: "Статические маршруты",
                   subtitle: "\(Format.routes(session.state?.staticRoutes.count ?? 0)) в конфигурации роутера")
    }

    private var selectionPill: some View {
        StatusPill(text: "выбрано: \(selectedRoutes.count)",
                   tint: selectedRoutes.isEmpty ? .secondary : Palette.accent)
    }

    private var routeSearchField: some View {
        TextField("Поиск по сети, интерфейсу или комментарию", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 180, idealWidth: 300, maxWidth: 360)
    }

    private var primaryRouteActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                addRouteButton
                deleteRoutesButton
            }
            .frame(minWidth: 300, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                addRouteButton
                deleteRoutesButton
            }
        }
    }

    private var addRouteButton: some View {
        Button("Добавить…") { showAdd = true }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(session.state == nil || session.progress != nil)
    }

    private var deleteRoutesButton: some View {
        Button("Удалить выбранные") { buildDeletePlan() }
            .buttonStyle(SubtleButtonStyle(tint: Palette.danger))
            .disabled(selectedRoutes.isEmpty || session.progress != nil)
    }

    private var transferActions: some View {
        HStack(spacing: 10) {
            Button("Импорт из BAT/TXT…") { importFile() }
                .buttonStyle(SubtleButtonStyle())

            Menu(selectedRoutes.isEmpty ? "Экспорт" : "Экспорт выбранных") {
                Button("В BAT для Windows…") { export(bat: true) }
                Button("В команды Keenetic…") { export(bat: false) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled((session.state?.staticRoutes.isEmpty ?? true))
        }
    }

    // MARK: - Таблица

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.state == nil {
                EmptyHint(icon: "bolt.horizontal.circle", title: "Роутер не прочитан",
                          message: "Подключись и нажми «Обновить».")
            } else if routes.isEmpty {
                EmptyHint(icon: "tray", title: "Маршрутов нет",
                          message: query.isEmpty
                            ? "Добавь первый маршрут или импортируй список из BAT-файла."
                            : "По запросу «\(query)» ничего не нашлось.")
            } else {
                AdaptiveTable(minContentWidth: 760) {
                    LazyVStack(spacing: 0) {
                        routeHeader
                        Divider()
                        ForEach(routes) { route in
                            row(route)
                            Divider()
                        }
                    }
                }
            }
        }
        .card(padding: 0)
    }

    private var routeHeader: some View {
        HStack(spacing: 10) {
            let visibleIDs = Set(routes.map(\.id))
            let allPicked = !routes.isEmpty && visibleIDs.isSubset(of: selection)
            Button {
                selection = allPicked ? selection.subtracting(visibleIDs)
                                      : selection.union(visibleIDs)
            } label: {
                Image(systemName: allPicked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .frame(width: 18)

            Text("Назначение").frame(width: 210, alignment: .leading)
            Text("Через").frame(width: 170, alignment: .leading)
            Text("Флаги").frame(width: 120, alignment: .leading)
            Text("Комментарий").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 9)
    }

    private func row(_ route: StaticRoute) -> some View {
        let isSelected = selection.contains(route.id)

        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Palette.accent : Color.secondary.opacity(0.45))
                .frame(width: 18)

            HStack(spacing: 6) {
                Text(route.family.title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                Text(route.destination)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
            }
            .frame(width: 210, alignment: .leading)
            .help(route.rawLine.isEmpty ? route.command : route.rawLine)

            VStack(alignment: .leading, spacing: 1) {
                let note = session.state?.note(for: route.via)
                Text(note ?? route.via)
                    .font(.system(size: 12, weight: note == nil ? .regular : .medium,
                                  design: note == nil ? .monospaced : .default))
                    .lineLimit(1)
                if note != nil {
                    Text(route.via)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 170, alignment: .leading)
            .help(session.state?.label(for: route.via) ?? route.via)

            HStack(spacing: 4) {
                if route.auto { StatusPill(text: "auto", tint: Palette.success) }
                if route.reject { StatusPill(text: "reject", tint: Palette.danger) }
                Spacer(minLength: 0)
            }
            .frame(width: 120, alignment: .leading)

            Text(route.comment.isEmpty ? "—" : route.comment)
                .font(.system(size: 11))
                .foregroundStyle(route.comment.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(route.comment)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selection.remove(route.id) } else { selection.insert(route.id) }
        }
        .contextMenu {
            Button("Скопировать команду") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(route.rawLine.isEmpty ? route.command : route.rawLine,
                                               forType: .string)
            }
            Button("Удалить", role: .destructive) {
                var built = Plan(title: "Удаление маршрута")
                built.commands = [route.deleteCommand]
                plan = built.forRouter(session.router)
            }
        }
    }

    // MARK: - Действия

    private func buildDeletePlan() {
        let victims = selectedRoutes
        guard !victims.isEmpty else { return }
        var built = Plan(title: "Удаление \(Format.routes(victims.count))")
        built.commands = victims.map(\.deleteCommand)
        plan = built.forRouter(session.router)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .data]
        panel.message = "Выбери BAT, CMD или TXT со списком маршрутов"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let data = try? Data(contentsOf: url) else {
            alert = AlertPayload(title: "Не читается файл", message: url.lastPathComponent)
            return
        }
        // BAT-файлы из Windows часто в CP866 — пробуем оба варианта.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: String.Encoding(rawValue:
                CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosRussian.rawValue))))
            ?? String(decoding: data, as: UTF8.self)

        let parsed = StaticRouteParser.parseImport(text)
        guard !parsed.routes.isEmpty else {
            alert = AlertPayload(title: "Маршрутов не нашлось",
                                 message: "В файле \(url.lastPathComponent) не распознано ни одной строки маршрута.")
            return
        }
        importPreview = parsed.routes
        importSkipped = parsed.skipped
        showImport = true
    }

    private func export(bat: Bool) {
        // Если что-то выделено — выгружаем выделенное, иначе всё.
        let chosen = selectedRoutes
        let all = chosen.isEmpty ? (session.state?.staticRoutes ?? []) : chosen
        guard !all.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = bat
            ? "keenetic-routes_\(Format.stamp()).bat"
            : "keenetic-routes_\(Format.stamp()).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = bat ? StaticRouteParser.exportBAT(all) : StaticRouteParser.exportCLI(all)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            log(.ok, "Экспортировано \(Format.routes(all.count)): \(url.path)")

            // Windows не умеет IPv6, reject и маршрут по умолчанию — говорим
            // об этом прямо, а не оставляем человека гадать, куда делись строки.
            let unsupported = bat ? StaticRouteParser.batUnsupported(all) : []
            if !unsupported.isEmpty {
                log(.warn, "В BAT не переносятся \(Format.routes(unsupported.count)) — "
                    + "они записаны комментарием rem.")
                alert = AlertPayload(
                    title: "Экспортировано с оговоркой",
                    message: "\(Format.routes(unsupported.count)) Windows выполнить не сможет: "
                           + "IPv6, запрещающие (reject) и маршрут по умолчанию. "
                           + "В файле они остались строками rem — ничего не потерялось.",
                    isError: false)
            }
        } catch {
            alert = AlertPayload(title: "Не удалось сохранить", message: error.localizedDescription)
        }
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

// MARK: - Добавление маршрута

struct RouteEditor: View {
    let interfaces: [KeeneticInterface]
    var onAdd: (StaticRoute) -> Void
    var onCancel: () -> Void

    @State private var family: StaticRoute.Family = .ipv4
    @State private var destination = ""
    @State private var via = ""
    @State private var metric = ""
    @State private var auto = true
    @State private var reject = false
    @State private var comment = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(icon: "plus.circle", title: "Новый статический маршрут",
                       subtitle: "Проверка формата — до отправки на роутер")

            Picker("Семейство", selection: $family) {
                ForEach(StaticRoute.Family.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 4) {
                Text("Сеть или узел назначения")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField(family == .ipv4 ? "10.0.0.0/8, 1.2.3.4 или default" : "2001:db8::/32 или default",
                          text: $destination)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Через интерфейс или шлюз")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Wireguard0 или 192.168.1.1", text: $via)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Menu {
                        ForEach(interfaces) { item in
                            Button(item.displayName + (item.isUp ? " ✓" : "")) { via = item.ident }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 34)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    routeFlags
                }
                .frame(minWidth: 330, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    routeFlags
                }
            }
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 4) {
                Text("Комментарий").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("необязательно", text: $comment)
                    .textFieldStyle(.roundedBorder)
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    editorCancelButton
                    Spacer()
                    editorAddButton
                }
                .frame(minWidth: 320)

                VStack(alignment: .leading, spacing: 8) {
                    editorAddButton
                    editorCancelButton
                }
            }
        }
        .padding(22)
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 520)
        .background(Palette.surface)
    }

    @ViewBuilder
    private var routeFlags: some View {
        Toggle("auto", isOn: $auto)
        Toggle("reject", isOn: $reject)
        TextField("метрика", text: $metric)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 100)
            .help("Необязательно. Меньшая метрика — более приоритетный маршрут.")
    }

    private var editorCancelButton: some View {
        Button("Отмена", action: onCancel)
            .buttonStyle(SubtleButtonStyle())
            .keyboardShortcut(.cancelAction)
    }

    private var editorAddButton: some View {
        Button("Добавить") { submit() }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
    }

    private func submit() {
        do {
            let trimmedMetric = metric.trimmingCharacters(in: .whitespaces)
            let metricValue: Int?
            if trimmedMetric.isEmpty {
                metricValue = nil
            } else if let value = Int(trimmedMetric), value >= 0 {
                metricValue = value
            } else {
                throw TransportError("Метрика должна быть целым числом не меньше нуля.")
            }
            try StaticRoute.validate(family: family, destination: destination, via: via,
                                     metric: metricValue, comment: comment)
            onAdd(StaticRoute(
                family: family,
                destination: destination.trimmingCharacters(in: .whitespaces),
                via: via.trimmingCharacters(in: .whitespaces),
                metric: metricValue,
                auto: auto, reject: reject,
                comment: comment.trimmingCharacters(in: .whitespaces)))
        } catch {
            self.error = (error as? TransportError)?.message ?? error.localizedDescription
        }
    }
}

// MARK: - Предпросмотр импорта

struct ImportPreview: View {
    let routes: [StaticRoute]
    let skipped: [String]
    var onAccept: ([StaticRoute]) -> Void
    var onCancel: () -> Void

    @State private var excluded: Set<String> = []

    private var accepted: [StaticRoute] { routes.filter { !excluded.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                CardHeader(icon: "square.and.arrow.down", title: "Импорт маршрутов",
                           subtitle: "Распознано \(Format.routes(routes.count))"
                                   + (skipped.isEmpty ? "" : ", пропущено строк: \(skipped.count)"))
                Spacer()
            }
            .padding(18)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(routes) { route in
                        let isOn = !excluded.contains(route.id)
                        HStack(spacing: 10) {
                            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13))
                                .foregroundStyle(isOn ? Palette.accent : Color.secondary.opacity(0.45))
                            Text(route.command)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isOn { excluded.insert(route.id) } else { excluded.remove(route.id) }
                        }
                        Divider()
                    }

                    if !skipped.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Пропущенные строки")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.warning)
                                .padding(.top, 10)
                            ForEach(Array(skipped.prefix(30).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            if skipped.count > 30 {
                                Text("… и ещё \(skipped.count - 30)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(Palette.canvas)

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack {
                    importCancelButton
                    importToggleAllButton
                    Spacer()
                    importCount
                    importPlanButton
                }
                .frame(minWidth: 470)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        importCancelButton
                        importToggleAllButton
                    }
                    HStack {
                        importCount
                        Spacer()
                        importPlanButton
                    }
                }
            }
            .padding(16)
        }
        .frame(minWidth: 500, idealWidth: 720, maxWidth: 720,
               minHeight: 440, idealHeight: 560, maxHeight: 560)
        .background(Palette.surface)
    }

    private var importCancelButton: some View {
        Button("Отмена", action: onCancel)
            .buttonStyle(SubtleButtonStyle())
            .keyboardShortcut(.cancelAction)
    }

    private var importToggleAllButton: some View {
        Button(excluded.isEmpty ? "Снять все" : "Выбрать все") {
            excluded = excluded.isEmpty ? Set(routes.map(\.id)) : []
        }
        .buttonStyle(SubtleButtonStyle())
    }

    private var importCount: some View {
        Text("К добавлению: \(accepted.count)")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var importPlanButton: some View {
        Button("Составить план") { onAccept(accepted) }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(accepted.isEmpty)
            .keyboardShortcut(.defaultAction)
    }
}
