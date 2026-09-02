import SwiftUI

struct FqdnView: View {
    @EnvironmentObject private var session: RouterSession
    @ObservedObject private var store = Store.shared
    @Binding var alert: AlertPayload?

    @State private var selected: Set<String> = []
    @State private var removeStale = Store.shared.settings.removeStaleByDefault
    @State private var forceRefresh = false
    @State private var loaded: [String: SourceData] = [:]
    @State private var plan: Plan?
    @State private var outcome: ApplyOutcome?
    @State private var working = false
    @State private var editingSource: CustomSource?
    @State private var manualListEditor = false
    @State private var planApplyTitle = "Загрузить на роутер"

    private let columns = [GridItem(.adaptive(minimum: 290), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let progress = session.progress { ProgressBanner(info: progress) }
                intro
                sources
                options
            }
            .padding(20)
        }
        .sheet(item: $editingSource) { source in
            SourceEditor(source: source, existing: store.customSources) { saved in
                editingSource = nil
                if store.customSources.contains(where: { $0.id == saved.id }) {
                    store.updateSource(saved)
                } else {
                    store.addSource(saved)
                }
            } onDelete: {
                editingSource = nil
                store.removeSource(source)
                selected.remove(source.spec.key)
            } onCancel: { editingSource = nil }
        }
        .sheet(isPresented: $manualListEditor) {
            ManualListEditor { ident, description, entries in
                do {
                    guard let state = session.state else {
                        throw TransportError("Сначала прочитай конфигурацию роутера.",
                                             hint: "Так приложение сможет проверить, что имя списка ещё свободно.")
                    }
                    let cleanIdent = ident.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !state.groups.keys.contains(where: {
                        $0.caseInsensitiveCompare(cleanIdent) == .orderedSame
                    }) else {
                        throw TransportError("Список «\(cleanIdent)» уже есть на роутере.",
                                             hint: "Выбери другое имя или управляй существующим списком на вкладке «Маршруты».")
                    }
                    let built = try ManualFqdnPlanner.plan(
                        ident: cleanIdent, description: description, entriesText: entries)
                    planApplyTitle = "Создать список"
                    plan = built.forRouter(session.router)
                    // Закрываем редактор только после успешной проверки.
                    // При ошибке человек остаётся в форме и может исправить
                    // одну строку, не вводя весь список заново.
                    manualListEditor = false
                } catch {
                    alert = AlertPayload(title: "Список не создан",
                                         message: session.describe(error))
                }
            } onCancel: { manualListEditor = false }
        }
        .sheet(item: Binding(get: { plan.map(PlanBox.init) }, set: { plan = $0?.plan })) { box in
            PlanSheet(plan: box.plan, applyTitle: planApplyTitle) { dryRun in
                plan = nil
                Task { await apply(box.plan, dryRun: dryRun) }
            } onCancel: {
                plan = nil
            }
        }
        .sheet(item: Binding(get: { outcome.map(OutcomeBox.init) }, set: { outcome = $0?.outcome })) { box in
            OutcomeSheet(title: "Загрузка списков FQDN", outcome: box.outcome) { outcome = nil }
        }
    }

    // MARK: - Шапка

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "list.bullet.rectangle", title: "Загрузка списков доменов",
                       subtitle: "Импорт наполняет object-group fqdn и НИКОГДА не трогает маршруты")

            Text("Домены и подсети раскладываются по частям не больше \(store.settings.chunkSize) записей — "
                 + "как того требует прошивка. Части нумеруются автоматически.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let state = session.state {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        sourceStats(state)
                    }
                    .frame(minWidth: 390, alignment: .leading)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        sourceStats(state)
                    }
                }
            }
        }
        .card()
    }

    // MARK: - Источники

    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    sourcesHeader
                    Spacer()
                    sourceActions
                }
                .frame(minWidth: 680)

                VStack(alignment: .leading, spacing: 10) {
                    sourcesHeader
                    sourceActions
                }
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(store.allSources) { spec in
                    sourceCard(spec)
                }
            }
        }
        .card()
    }

    private var sourcesHeader: some View {
        CardHeader(icon: "square.stack.3d.up", title: "Источники",
                   subtitle: "Отметь то, что хочешь залить — можно несколько сразу")
    }

    private var sourceActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                manualListButton
                customSourceButton
                selectAllSourcesButton
            }
            .frame(minWidth: 460)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    manualListButton
                    customSourceButton
                }
                selectAllSourcesButton
            }
        }
    }

    private var manualListButton: some View {
        Button("Список вручную…") { manualListEditor = true }
            .buttonStyle(SubtleButtonStyle())
    }

    private var customSourceButton: some View {
        Button("Свой источник…") { editingSource = CustomSource() }
            .buttonStyle(SubtleButtonStyle())
    }

    private var selectAllSourcesButton: some View {
        Button(selected.count == store.allSources.count ? "Снять все" : "Выбрать все") {
            selected = selected.count == store.allSources.count
                ? []
                : Set(store.allSources.map(\.key))
        }
        .buttonStyle(SubtleButtonStyle())
    }

    @ViewBuilder
    private func sourceStats(_ state: RouterState) -> some View {
        StatusPill(text: "\(Format.lists(state.groups.count)) на роутере", tint: Palette.accent)
        StatusPill(text: "\(Format.domains(state.totalDomains))", tint: Palette.success)
        StatusPill(text: "прочитано \(Format.age(state.readAt))", tint: .secondary)
    }

    private func sourceCard(_ spec: SourceSpec) -> some View {
        let isSelected = selected.contains(spec.key)
        let data = loaded[spec.key]

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: spec.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Palette.accent : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.title).font(.system(size: 13, weight: .semibold))
                    Text(spec.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Palette.accent : Color.secondary.opacity(0.4))
            }

            if let mine = custom(spec) {
                HStack(spacing: 6) {
                    StatusPill(text: "свой", tint: Palette.accent)
                    Button("Изменить") { editingSource = mine }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
            }

            if let data {
                HStack(spacing: 6) {
                    StatusPill(text: "\(data.entries.count) записей", tint: Palette.success)
                    if data.subnetCount > 0 {
                        StatusPill(text: "\(data.subnetCount) подсетей", tint: Palette.accent)
                    }
                    StatusPill(text: data.freshness, tint: .secondary)
                }
            } else if !spec.subnetURLs.isEmpty {
                StatusPill(text: "домены + подсети", tint: .secondary)
            }

            if let state = session.state {
                let managed = Planner.managedGroups(state.groups, spec: spec)
                if !managed.isEmpty {
                    let total = managed.reduce(0) { $0 + $1.includes.count }
                    Text("Уже на роутере: \(Format.lists(managed.count)) · \(Format.domains(total))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(isSelected ? Palette.accent.opacity(0.07) : Palette.inset))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(isSelected ? Palette.accent.opacity(0.5) : Palette.stroke, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selected.remove(spec.key) } else { selected.insert(spec.key) }
        }
        .contextMenu {
            if let mine = custom(spec) {
                Button("Изменить источник…") { editingSource = mine }
                Button("Удалить источник", role: .destructive) {
                    store.removeSource(mine)
                    selected.remove(spec.key)
                }
            }
        }
    }

    /// Свой ли это источник — по нему доступны правка и удаление.
    private func custom(_ spec: SourceSpec) -> CustomSource? {
        store.customSources.first { $0.spec.key == spec.key }
    }

    // MARK: - Параметры и запуск

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: "slider.horizontal.3", title: "Как загружать")

            Toggle(isOn: $removeStale) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Убирать домены, которых больше нет в источнике")
                        .font(.system(size: 12, weight: .medium))
                    Text("Списки остаются точной копией источника, а не растут вечно.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $forceRefresh) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Принудительно перекачать источники")
                        .font(.system(size: 12, weight: .medium))
                    Text(store.settings.cacheTTLMinutes > 0
                         ? "Иначе берётся кэш, если ему меньше \(store.settings.cacheTTLMinutes) мин."
                         : "Кэш выключен в настройках — источники и так качаются заново каждый раз.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    buildPlanButton
                    selectedSourcesLabel
                    Spacer()
                    safetyNote
                }
                .frame(minWidth: 650)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        buildPlanButton
                        selectedSourcesLabel
                    }
                    safetyNote
                }
            }
        }
        .card()
    }

    private var buildPlanButton: some View {
        Button {
            Task { await buildPlan() }
        } label: {
            HStack(spacing: 6) {
                if working { ProgressView().controlSize(.small) }
                Text(working ? "Считаю план…" : "Составить план")
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(selected.isEmpty || working || session.progress != nil)
    }

    @ViewBuilder
    private var selectedSourcesLabel: some View {
        if !selected.isEmpty {
            Text("Выбрано источников: \(selected.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var safetyNote: some View {
        Text("Ничего не уйдёт на роутер, пока ты не подтвердишь план.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Действия

    private func buildPlan() async {
        working = true
        defer { working = false }
        planApplyTitle = "Загрузить на роутер"
        let operation = session.beginOperation()
        let profile = session.router
        let conflicts = CustomSource.conflictingSourceTitles(store.allSources)
        guard conflicts.isEmpty else {
            alert = AlertPayload(
                title: "Источники спорят за один список",
                message: "Исправь префикс у одного из источников: "
                    + conflicts.joined(separator: "; ") + ".",
                isError: true)
            return
        }

        do {
            let state: RouterState
            if let cached = session.state {
                state = cached
            } else {
                state = try await session.refresh(operation: operation)
            }

            var plans: [Plan] = []
            var reserved = Set(state.groups.keys)
            var fetched: [String: SourceData] = loaded

            for spec in store.allSources where selected.contains(spec.key) {
                guard session.isCurrent(operation) else {
                    throw TransportError("Профиль роутера изменился во время подготовки плана.",
                                         hint: "Повтори загрузку для обновлённого профиля.")
                }
                let data = try await session.loadSource(spec, forceRefresh: forceRefresh)
                fetched[spec.key] = data
                log(.info, "\(spec.title): \(data.entries.count) записей, \(data.freshness).")

                plans.append(Planner.planImport(
                    groups: state.groups,
                    data: data,
                    chunkSize: store.settings.chunkSize,
                    removeStale: removeStale,
                    reservedIDs: &reserved))
            }

            loaded = fetched

            let merged = Planner.merge(
                title: plans.count == 1 ? plans[0].title : "Загрузка \(Format.lists(plans.count))",
                plans: plans)

            if merged.isEmpty {
                alert = AlertPayload(
                    title: "Изменений не требуется",
                    message: "Списки на роутере уже совпадают с источниками.",
                    isError: false)
                return
            }
            guard session.isCurrent(operation) else {
                alert = AlertPayload(
                    title: "Роутер переключён",
                    message: "План был рассчитан по конфигурации другого роутера. Выбери источники и составь его заново.",
                    isError: false)
                return
            }
            plan = merged.forRouter(profile)
        } catch {
            alert = AlertPayload(title: "Не удалось составить план", message: session.describe(error))
        }
    }

    private func apply(_ plan: Plan, dryRun: Bool) async {
        do {
            let result = try await session.apply(plan: plan, dryRun: dryRun,
                                                 saveConfig: store.settings.saveConfigAfterApply)
            if result.applied { outcome = result }
        } catch {
            alert = AlertPayload(title: "Не удалось применить план", message: session.describe(error))
        }
    }
}

/// Обёртки, чтобы показывать sheet по значению без Identifiable на модели.
struct PlanBox: Identifiable {
    let plan: Plan
    var id: UUID { plan.id }
    init(_ plan: Plan) { self.plan = plan }
}

struct OutcomeBox: Identifiable {
    let outcome: ApplyOutcome
    var id: UUID { outcome.id }
    init(_ outcome: ApplyOutcome) { self.outcome = outcome }
}

// MARK: - Свой источник

struct SourceEditor: View {
    @State var source: CustomSource
    let existing: [CustomSource]
    var onSave: (CustomSource) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @State private var urlText = ""
    @State private var subnetText = ""
    @State private var error: String?
    @State private var loaded = false

    private var isNew: Bool { !existing.contains { $0.id == source.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: "link", title: isNew ? "Новый источник" : source.title,
                       subtitle: "Список доменов по адресу или из файла на диске")

            field("Название") {
                TextField("Мой список", text: $source.title).textFieldStyle(.roundedBorder)
            }

            field("Префикс описания на роутере") {
                TextField("my list", text: $source.descriptionPrefix)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Text("Части списка получат описания «\(prefixPreview) 1», «\(prefixPreview) 2» — "
                     + "по ним приложение потом узнаёт свои списки и пополняет именно их.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("Адреса списка") {
                TextEditor(text: $urlText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 62)
                    .padding(4)
                    .inset()
                Text("По одному в строке. Можно http://, https:// или путь к файлу "
                     + "от корня. Несколько строк — это зеркала ОДНОГО списка: "
                     + "пробуются по очереди до первого удачного.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("Адреса подсетей (необязательно)") {
                TextEditor(text: $subnetText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 44)
                    .padding(4)
                    .inset()
            }

            field("Минимум записей", width: 150) {
                TextField("1", value: $source.minDomains, format: .number)
                    .textFieldStyle(.roundedBorder)
                Text("Меньше — загрузка считается неудачной.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
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
                if !isNew {
                    Button("Удалить", action: onDelete)
                        .buttonStyle(SubtleButtonStyle(tint: Palette.danger))
                }
                Spacer()
                Button(isNew ? "Добавить" : "Сохранить") { submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 440, idealWidth: 560, maxWidth: 560)
        .background(Palette.surface)
        .onAppear {
            guard !loaded else { return }
            urlText = source.urls.joined(separator: "\n")
            subnetText = source.subnetURLs.joined(separator: "\n")
            loaded = true
        }
    }

    private var prefixPreview: String {
        let value = source.descriptionPrefix.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "my list" : value
    }

    private func submit() {
        var cleaned = source
        cleaned.title = cleaned.title.trimmingCharacters(in: .whitespaces)
        cleaned.descriptionPrefix = cleaned.descriptionPrefix.trimmingCharacters(in: .whitespaces)
        cleaned.urls = CustomSource.addresses(from: urlText)
        cleaned.subnetURLs = CustomSource.addresses(from: subnetText)
        do {
            try CustomSource.validate(cleaned, existing: existing)
            onSave(cleaned)
        } catch {
            self.error = (error as? TransportError)?.message ?? error.localizedDescription
        }
    }

    private func field<Content: View>(_ title: String, width: CGFloat? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - Список вручную

/// Маленький список удобнее создать прямо здесь, без временного файла или
/// отдельного URL-источника. После применения он становится обычным списком
/// роутера и доступен на вкладке «Маршруты».
struct ManualListEditor: View {
    @State private var ident = "test"
    @State private var description = "test"
    @State private var entries = "2ip.io\nwhoer.net"

    var onSave: (_ ident: String, _ description: String, _ entries: String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            CardHeader(icon: "list.bullet.rectangle",
                       title: "Новый список маршрутов",
                       subtitle: "Создаёт object-group fqdn без внешнего источника")

            field("Имя списка") {
                TextField("test", text: $ident)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Text("Латиница, цифры, дефис и подчёркивание — до 32 символов.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            field("Описание на роутере") {
                TextField("test", text: $description)
                    .textFieldStyle(.roundedBorder)
                Text("По описанию список потом легко найти среди маршрутов.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            field("Домены и IP-адреса") {
                TextEditor(text: $entries)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 150)
                    .padding(4)
                    .inset()
                Text("По одному значению в строке. Поддерживаются домены, IPv4/IPv6 и CIDR; комментарии начинаются с #.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Отмена", action: onCancel)
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Показать план") {
                    onSave(ident, description, entries)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 440, idealWidth: 560, maxWidth: 560)
        .background(Palette.surface)
    }

    private func field<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }
}
