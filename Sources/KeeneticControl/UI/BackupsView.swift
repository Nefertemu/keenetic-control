import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BackupsView: View {
    @EnvironmentObject private var session: RouterSession
    @Binding var alert: AlertPayload?

    /// Размер и дату файла собираем один раз при обновлении списка.
    /// Раньше это читалось с диска прямо в body — на каждую перерисовку.
    private struct Snapshot: Identifiable, Hashable {
        let url: URL
        let date: Date?
        let size: Int
        let host: String
        var id: URL { url }
    }

    /// Результат сверки привязан и к снимку, и к роутеру, с которого была
    /// прочитана текущая конфигурация. Иначе при смене роутера между сверкой
    /// и нажатием «вернуть» команды из A могли бы уйти в B.
    private struct ComparisonResult: Identifiable {
        let operation: RouterOperation
        let snapshot: URL
        let difference: Restore.Difference
        var id: UUID { difference.id }
    }

    @State private var files: [Snapshot] = []
    @State private var selection: URL?
    @State private var preview = ""
    @State private var loadingPreview = false
    @State private var onlyThisRouter = true
    @State private var comparison: ComparisonResult?
    @State private var comparisonID: UUID?
    @State private var takingSnapshot = false
    private var comparing: Bool { comparisonID != nil }
    @State private var plan: Plan?
    @State private var outcome: ApplyOutcome?
    @State private var portableRequest: PortableBackupRequest?

    private var selected: Snapshot? {
        guard let selection else { return nil }
        return visible.first { $0.url == selection }
    }

    private var visible: [Snapshot] {
        guard onlyThisRouter else { return files }
        let mine = Backups.safeHost(session.router.backupHost)
        return files.filter { $0.host == mine }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                list
                    .frame(width: 340)
                detail
            }
            .frame(minWidth: 720)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    list
                        .frame(minHeight: 300, maxHeight: 380)
                    detail
                        .frame(minHeight: 420)
                }
            }
        }
        .padding(20)
        .onAppear(perform: reload)
        .sheet(item: $comparison) { result in
            RestorePreview(difference: result.difference, snapshot: result.snapshot.lastPathComponent) { chosen in
                comparison = nil
                guard session.isCurrent(result.operation),
                      session.activeRouterID == result.operation.routerID else {
                    alert = AlertPayload(
                        title: "Роутер переключён",
                        message: "Сверка относилась к другому роутеру. Выбери снимок и повтори её.",
                        isError: false)
                    return
                }
                do {
                    plan = try Restore.validatedPlan(chosen,
                        chunkSize: Store.shared.settings.chunkSize,
                        title: "Возврат к копии", verificationLimit: Store.shared.settings.maxDomainsPerList)
                        .forRouter(session.router)
                } catch { alert = AlertPayload(title: "Не удалось собрать план", message: session.describe(error)) }
            } onCancel: { comparison = nil }
        }
        .sheet(item: Binding(get: { plan.map(PlanBox.init) }, set: { plan = $0?.plan })) { box in
            PlanSheet(plan: box.plan, applyTitle: "Вернуть как было", state: session.state) { dryRun in
                plan = nil
                Task { await apply(box.plan, dryRun: dryRun) }
            } onCancel: { plan = nil }
        }
        .sheet(item: Binding(get: { outcome.map(OutcomeBox.init) }, set: { outcome = $0?.outcome })) { box in
            OutcomeSheet(title: "Возврат к резервной копии", outcome: box.outcome) { outcome = nil }
        }
        .sheet(item: $portableRequest) { request in
            PortableBackupSheet(request: request) { imported in
                portableRequest = nil
                reload()
                if let imported { onlyThisRouter = false; select(imported) }
            } onCancel: { portableRequest = nil }
        }
        .onChange(of: onlyThisRouter) { _, _ in reconcileSelection() }
        .onDisappear { comparisonID = nil }
        .onChange(of: RouterPresentationContext(session.router)) { _, _ in
            reconcileSelection()
            comparisonID = nil
            comparison = nil
            plan = nil
            outcome = nil
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeader(icon: "clock.arrow.circlepath", title: "Резервные копии",
                           subtitle: "Снимаются автоматически перед каждым изменением")
                Spacer()
                Button {
                    NSWorkspace.shared.open(AppPaths.backups)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Открыть папку")
            }

            HStack(spacing: 8) {
                Button(takingSnapshot ? "Снимаю копию…" : "Снять копию сейчас") {
                    Task { await snapshot() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(takingSnapshot || session.progress != nil)
                Button("Обновить") { reload() }
                    .buttonStyle(SubtleButtonStyle())
            }

            Button("Импорт копии с паролем…", action: importPortable)
                .buttonStyle(SubtleButtonStyle())
                .help("Открыть переносимую копию, в том числе созданную на другом Mac")

            Toggle(isOn: $onlyThisRouter) {
                Text("Только «\(session.router.name)»")
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .help(session.router.name)
            }
            .toggleStyle(.checkbox)
            .help("Снимки всех роутеров лежат в одной папке — фильтр оставляет только этот")

            if visible.isEmpty {
                EmptyHint(icon: "tray", title: files.isEmpty ? "Копий пока нет" : "Для этого роутера копий нет",
                          message: files.isEmpty
                            ? "Первая появится перед первым изменением конфигурации."
                            : "Сними копию сейчас или сними галочку, чтобы увидеть остальные.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { item in
                            row(item)
                            if item.id != visible.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .inset()
            }
        }
        .card()
    }

    private func row(_ item: Snapshot) -> some View {
        let selected = selection == item.url

        return HStack(spacing: 9) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(selected ? Palette.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.date.map(Format.humanDate) ?? item.url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(item.host.isEmpty ? "—" : item.host) · \(Format.bytes(item.size))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Palette.accent.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .help(item.url.lastPathComponent)
        .onTapGesture { select(item.url) }
        .contextMenu {
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Скопировать путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Button("Удалить", role: .destructive) {
                do {
                    try FileManager.default.removeItem(at: item.url)
                    if selection == item.url { clearSelection() }
                    reload()
                } catch {
                    alert = AlertPayload(title: "Копия не удалена", message: error.localizedDescription)
                }
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    detailHeader
                    Spacer()
                    detailActions
                }
                .frame(minWidth: 560)

                VStack(alignment: .leading, spacing: 10) {
                    detailHeader
                    detailActions
                }
            }

            if loadingPreview {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Читаю файл…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if preview.isEmpty {
                EmptyHint(icon: "doc.text.magnifyingglass", title: "Ничего не выбрано",
                          message: "Слева — все снимки конфигурации. Здесь будет их содержимое.")
            } else {
                ScrollView {
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .inset()
            }
        }
        .card()
    }

    private var detailHeader: some View {
        CardHeader(icon: "doc.plaintext",
                   title: selected.map { $0.date.map(Format.humanDate) ?? $0.url.lastPathComponent }
                     ?? "Содержимое копии",
                   subtitle: selected.map { "running-config · \($0.host) · \($0.url.lastPathComponent)" }
                     ?? "Выбери файл слева")
    }

    @ViewBuilder
    private var detailActions: some View {
        HStack(spacing: 8) {
            if selected != nil {
                Button {
                    Task { await compare() }
                } label: {
                    HStack(spacing: 6) {
                        if comparing { ProgressView().controlSize(.small) }
                        Text(comparing ? "Сверяю…" : "Сверить с роутером")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(comparing || session.progress != nil)
                .help("Показать, чем текущая конфигурация отличается от снимка, "
                      + "и собрать план возврата")
            }
            if selected != nil {
                Button("Экспорт с паролем…", action: exportPortable)
                    .buttonStyle(SubtleButtonStyle())
                    .disabled(loadingPreview)
            }
            if !preview.isEmpty {
                Button("Копировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(preview, forType: .string)
                }
                .buttonStyle(SubtleButtonStyle())
            }
        }
    }

    private func importPortable() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: PortableBackup.pathExtension) ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Переносимая копия с паролем"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        portableRequest = PortableBackupRequest(mode: .importFile(url), host: session.router.backupHost)
    }

    private func exportPortable() {
        guard let source = selected?.url else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: PortableBackup.pathExtension) ?? .data]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "." + PortableBackup.pathExtension
        panel.message = "Сохранить копию для переноса на другой Mac"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        portableRequest = PortableBackupRequest(mode: .exportFile(source, target), host: session.router.backupHost)
    }

    private func reload() {
        files = Backups.list().map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Snapshot(url: url,
                            date: values?.contentModificationDate,
                            size: values?.fileSize ?? 0,
                            host: Backups.host(of: url))
        }
        reconcileSelection()
    }

    private func reconcileSelection() {
        if let selection, !visible.contains(where: { $0.url == selection }) { clearSelection() }
    }

    private func clearSelection() {
        selection = nil
        comparisonID = nil
        comparison = nil
        preview = ""
        loadingPreview = false
    }

    /// Конфигурация бывает и на мегабайт — читаем её не на главном потоке.
    private func select(_ url: URL) {
        comparisonID = nil
        comparison = nil
        selection = url
        preview = ""
        loadingPreview = true
        Task {
            let text = await Task.detached {
                (try? Backups.read(url)) ?? "Файл не читается или не удалось расшифровать копию."
            }.value
            guard selection == url else { return }
            preview = text
            loadingPreview = false
        }
    }

    /// Сверка снимка с тем, что на роутере сейчас.
    private func compare() async {
        guard let url = selected?.url, comparisonID == nil else { return }
        let operation = session.beginOperation()
        let requestID = UUID()
        comparisonID = requestID
        defer { if comparisonID == requestID { comparisonID = nil } }
        func isRelevant() -> Bool {
            comparisonID == requestID && selection == url
                && session.activeRouterID == operation.routerID && session.isCurrent(operation)
        }
        do {
            let backup = try await Task.detached {
                try Backups.read(url)
            }.value
            guard isRelevant() else { return }
            let current = try await session.readConfigText(operation: operation)
            let found = try Restore.validatedComparison(backup: backup, current: current)
            guard isRelevant() else { return }
            if found.isEmpty {
                alert = AlertPayload(
                    title: "Расхождений нет",
                    message: "Списки FQDN, их маршруты и статические маршруты "
                           + "совпадают со снимком.",
                    isError: false)
                return
            }
            comparison = ComparisonResult(operation: operation, snapshot: url, difference: found)
        } catch {
            guard isRelevant() else { return }
            alert = AlertPayload(title: "Не удалось сверить", message: session.describe(error))
        }
    }

    private func apply(_ plan: Plan, dryRun: Bool) async {
        let context = RouterPresentationContext(session.router)
        do {
            let result = try await session.apply(plan: plan, dryRun: dryRun,
                                                 saveConfig: Store.shared.settings.saveConfigAfterApply)
            guard context == RouterPresentationContext(session.router) else { return }
            if result.applied { outcome = result }
        } catch {
            guard context == RouterPresentationContext(session.router) else { return }
            alert = AlertPayload(title: "Возврат не удался", message: session.describe(error))
        }
    }

    private func snapshot() async {
        guard !takingSnapshot else { return }
        takingSnapshot = true
        defer { takingSnapshot = false }
        let operation = session.beginOperation()
        let profile = session.router
        do {
            let text = try await session.readConfigText(operation: operation)
            let url = Backups.saveRunningConfig(host: profile.backupHost, text: text,
                                                keep: Store.shared.settings.keepBackups)
            guard let url else {
                throw TransportError(
                    "Защищённая копия не создана.",
                    hint: "Проверь доступ приложения к связке ключей и свободное место на диске.")
            }
            log(.ok, "Защищённая копия конфигурации: \(url.lastPathComponent)")
            reload()
            if session.isCurrent(operation), session.activeRouterID == operation.routerID {
                select(url)
            }
        } catch {
            guard session.activeRouterID == operation.routerID, session.isCurrent(operation) else { return }
            alert = AlertPayload(title: "Не удалось снять копию", message: session.describe(error))
        }
    }
}

/// Что именно вернётся, до того как собран план команд.
struct RestorePreview: View {
    let difference: Restore.Difference
    let snapshot: String
    var onBuild: (Restore.Difference) -> Void
    @State private var restoreContents = true
    @State private var restoreChains = true
    @State private var restoreStatics = true
    @State private var selectedGroups: Set<String>? = nil

    private var allGroups: [String] {
        Set(difference.snapshotGroups.keys).union(difference.currentGroups.keys).sorted()
    }
    private var selectedDifference: Restore.Difference {
        Restore.selecting(.init(groupIDs: selectedGroups, restoreContents: restoreContents,
                                restoreChains: restoreChains, restoreStaticRoutes: restoreStatics), from: difference)
    }
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(icon: "clock.arrow.circlepath", title: "Возврат к резервной копии",
                       subtitle: snapshot)
                .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Что восстановить").font(.headline)
                        Toggle("Содержимое и имена списков", isOn: $restoreContents)
                        Toggle("Цепочки маршрутов списков", isOn: $restoreChains)
                        Toggle("Статические маршруты", isOn: $restoreStatics)
                        if restoreContents || restoreChains {
                            DisclosureGroup("Выбрать списки (\((selectedGroups ?? Set(allGroups)).count) из \(allGroups.count))") {
                                HStack {
                                    Button("Все") { selectedGroups = nil }
                                    Button("Ни одного") { selectedGroups = [] }
                                    Spacer()
                                }
                                ForEach(allGroups, id: \.self) { ident in
                                    Toggle(isOn: Binding(
                                        get: { (selectedGroups ?? Set(allGroups)).contains(ident) },
                                        set: { chosen in
                                            var next = selectedGroups ?? Set(allGroups)
                                            if chosen { next.insert(ident) } else { next.remove(ident) }
                                            selectedGroups = next
                                        })) {
                                            Text(groupTitle(ident)).lineLimit(2).help(groupTitle(ident))
                                        }
                                }
                            }
                        }
                    }.toggleStyle(.checkbox).padding(12).inset()

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        MetricTile(value: String(selectedDifference.missingDomainCount),
                                   label: "Вернуть доменов", icon: "arrow.uturn.backward",
                                   tint: Palette.success)
                        MetricTile(value: String(selectedDifference.extraDomainCount),
                                   label: "Убрать доменов", icon: "minus.circle",
                                   tint: Palette.danger)
                        MetricTile(value: String(selectedDifference.missingGroups.count),
                                   label: "Создать списков", icon: "folder.badge.plus",
                                   tint: Palette.accent)
                        MetricTile(value: String(selectedDifference.extraGroups.count),
                                   label: "Удалить списков", icon: "folder.badge.minus",
                                   tint: Palette.warning)
                    }

                    section("Имена списков вернутся", selectedDifference.changedDescriptions.sorted(by: { $0.key < $1.key }).map {
                        "\($0.key): \(selectedDifference.currentGroups[$0.key]?.descriptionText ?? "") → \($0.value.isEmpty ? "без имени" : $0.value)"
                    }, tint: Palette.accent)

                    section("Списки появятся заново", selectedDifference.missingGroups.map {
                        "\($0.ident) · \($0.descriptionText) · \(Format.domains($0.includes.count))"
                    }, tint: Palette.accent)

                    section("Списки будут удалены", selectedDifference.extraGroups.map {
                        "\($0.ident) · \($0.descriptionText) · \(Format.domains($0.includes.count))"
                    }, tint: Palette.warning)

                    section("Маршруты списков вернутся", selectedDifference.missingRouteLines,
                            tint: Palette.success)
                    section("Маршруты списков снимутся", selectedDifference.extraRouteLines,
                            tint: Palette.danger)
                    section("Статические маршруты вернутся",
                            selectedDifference.missingRoutes.map { $0.command + ($0.disabled ? " · выключен" : "") }, tint: Palette.success)
                    section("Статические маршруты снимутся",
                            selectedDifference.extraRoutes.map { $0.command + ($0.disabled ? " · выключен" : "") }, tint: Palette.danger)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                        Text("Возвращается только то, чем управляет приложение: списки FQDN, "
                             + "их маршруты и статические маршруты. Wi-Fi, NAT, межсетевой экран "
                             + "и прочее из снимка не трогаются. Удаление списка также снимает его маршруты.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }
            .background(Palette.canvas)

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack {
                    cancelButton
                    Spacer()
                    summaryText
                    buildButton
                }
                .frame(minWidth: 500)

                VStack(alignment: .leading, spacing: 8) {
                    summaryText
                    HStack {
                        cancelButton
                        Spacer()
                        buildButton
                    }
                }
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 760, maxWidth: 760,
               minHeight: 480, idealHeight: 620, maxHeight: 620)
        .background(Palette.surface)
    }

    private func groupTitle(_ ident: String) -> String {
        let name = difference.snapshotGroups[ident]?.descriptionText ?? difference.currentGroups[ident]?.descriptionText ?? ""
        return name.isEmpty ? ident : "\(name) · \(ident)"
    }

    private var cancelButton: some View {
        Button("Отмена", action: onCancel)
            .buttonStyle(SubtleButtonStyle())
            .keyboardShortcut(.cancelAction)
    }

    private var buildButton: some View {
        Button("Собрать план") { onBuild(selectedDifference) }
            .disabled(selectedDifference.isEmpty)
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
    }

    private var summaryText: some View {
        Text(selectedDifference.summary.joined(separator: " · "))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    @ViewBuilder
    private func section(_ title: String, _ lines: [String], tint: Color) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(String(lines.count))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(lines.prefix(40).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(line)
                }
                if lines.count > 40 {
                    Text("и ещё \(lines.count - 40)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .inset()
        }
    }
}
