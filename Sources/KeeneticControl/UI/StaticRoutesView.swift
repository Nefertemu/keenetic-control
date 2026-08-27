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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let progress = session.progress { ProgressBanner(info: progress) }
            toolbar
            table
        }
        .padding(20)
        .sheet(isPresented: $showAdd) {
            RouteEditor(interfaces: session.state?.candidates ?? []) { route in
                showAdd = false
                var built = Plan(title: "Добавление маршрута")
                built.commands = [route.command]
                plan = built
            } onCancel: { showAdd = false }
        }
        .sheet(isPresented: $showImport) {
            ImportPreview(routes: importPreview, skipped: importSkipped) { accepted in
                showImport = false
                guard !accepted.isEmpty else { return }
                var built = Plan(title: "Импорт \(Format.routes(accepted.count))")
                built.commands = accepted.map(\.command)
                built.notes = ["Маршруты добавляются как есть. Существующие такие же строки роутер просто перезапишет."]
                plan = built
            } onCancel: { showImport = false }
        }
        .sheet(item: Binding(get: { plan.map(PlanBox.init) }, set: { plan = $0?.plan })) { box in
            PlanSheet(plan: box.plan) { dryRun in
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
            HStack {
                CardHeader(icon: "point.topleft.down.to.point.bottomright.curvepath",
                           title: "Статические маршруты",
                           subtitle: "\(Format.routes(session.state?.staticRoutes.count ?? 0)) в конфигурации роутера")
                Spacer()
                StatusPill(text: "выбрано: \(selection.count)",
                           tint: selection.isEmpty ? .secondary : Palette.accent)
            }

            HStack(spacing: 10) {
                TextField("Поиск по сети, интерфейсу или комментарию", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 150, maxWidth: 320)

                Button("Добавить…") { showAdd = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(session.state == nil)

                Button("Удалить выбранные") { buildDeletePlan() }
                    .buttonStyle(SubtleButtonStyle(tint: Palette.danger))
                    .disabled(selection.isEmpty)

                Spacer()

                Button("Импорт из BAT/TXT…") { importFile() }
                    .buttonStyle(SubtleButtonStyle())

                Menu(selection.isEmpty ? "Экспорт" : "Экспорт выбранных") {
                    Button("В BAT для Windows…") { export(bat: true) }
                    Button("В команды Keenetic…") { export(bat: false) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled((session.state?.staticRoutes.isEmpty ?? true))
            }
        }
        .card()
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
                HStack(spacing: 10) {
                    Button {
                        selection = selection.count == routes.count ? [] : Set(routes.map(\.id))
                    } label: {
                        Image(systemName: selection.count == routes.count && !routes.isEmpty
                              ? "checkmark.square.fill" : "square")
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
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(routes) { route in
                            row(route)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .card(padding: 0)
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

            Text(route.via)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)

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
                plan = built
            }
        }
    }

    // MARK: - Действия

    private func buildDeletePlan() {
        let victims = routes.filter { selection.contains($0.id) }
        guard !victims.isEmpty else { return }
        var built = Plan(title: "Удаление \(Format.routes(victims.count))")
        built.commands = victims.map(\.deleteCommand)
        plan = built
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
        let everything = session.state?.staticRoutes ?? []
        let chosen = everything.filter { selection.contains($0.id) }
        let all = chosen.isEmpty ? everything : chosen
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
                _ = try? await session.refresh()
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
                            Button(item.ident) { via = item.ident }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 34)
                }
            }

            HStack(spacing: 16) {
                Toggle("auto", isOn: $auto)
                Toggle("reject", isOn: $reject)
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

            HStack {
                Button("Отмена", action: onCancel)
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Добавить") { submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Palette.surface)
    }

    private func submit() {
        do {
            try StaticRoute.validate(family: family, destination: destination, via: via)
            onAdd(StaticRoute(
                family: family,
                destination: destination.trimmingCharacters(in: .whitespaces),
                via: via.trimmingCharacters(in: .whitespaces),
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
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(Palette.canvas)

            Divider()

            HStack {
                Button("Отмена", action: onCancel)
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("К добавлению: \(accepted.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Составить план") { onAccept(accepted) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(accepted.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
        .background(Palette.surface)
    }
}
