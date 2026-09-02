import AppKit
import SwiftUI

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
    @State private var comparing = false
    @State private var plan: Plan?
    @State private var outcome: ApplyOutcome?

    private var selected: Snapshot? {
        guard let selection else { return nil }
        return files.first { $0.url == selection }
    }

    private var visible: [Snapshot] {
        guard onlyThisRouter else { return files }
        let mine = Backups.safeHost(session.router.host)
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
            RestorePreview(difference: result.difference, snapshot: result.snapshot.lastPathComponent) {
                comparison = nil
                guard session.isCurrent(result.operation),
                      session.activeRouterID == result.operation.routerID else {
                    alert = AlertPayload(
                        title: "Роутер переключён",
                        message: "Сверка относилась к другому роутеру. Выбери снимок и повтори её.",
                        isError: false)
                    return
                }
                plan = Restore.plan(result.difference, chunkSize: Store.shared.settings.chunkSize,
                                    title: "Возврат к копии")
                    .forRouter(session.router)
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
        .onChange(of: session.router.id) { _, _ in
            // Снимки лежат вперемешку, и выделенный принадлежал прошлому
            // роутеру — под фильтром «только этот» он просто исчезал бы.
            if onlyThisRouter, let selection,
               !visible.contains(where: { $0.url == selection }) { clearSelection() }
            if let comparison,
               comparison.operation.routerID != session.activeRouterID
                   || !session.isCurrent(comparison.operation) {
                self.comparison = nil
            }
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
                Button("Снять копию сейчас") { Task { await snapshot() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(session.progress != nil)
                Button("Обновить") { reload() }
                    .buttonStyle(SubtleButtonStyle())
            }

            Toggle(isOn: $onlyThisRouter) {
                Text("Только «\(session.router.name)»")
                    .font(.system(size: 11))
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
                try? FileManager.default.removeItem(at: item.url)
                if selection == item.url { clearSelection() }
                reload()
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
            if !preview.isEmpty {
                Button("Копировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(preview, forType: .string)
                }
                .buttonStyle(SubtleButtonStyle())
            }
        }
    }

    private func reload() {
        files = Backups.list().map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Snapshot(url: url,
                            date: values?.contentModificationDate,
                            size: values?.fileSize ?? 0,
                            host: Backups.host(of: url))
        }
        if let selection, !files.contains(where: { $0.url == selection }) { clearSelection() }
    }

    private func clearSelection() {
        selection = nil
        preview = ""
        loadingPreview = false
    }

    /// Конфигурация бывает и на мегабайт — читаем её не на главном потоке.
    private func select(_ url: URL) {
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
        guard let url = selection else { return }
        let operation = session.beginOperation()
        comparing = true
        defer { comparing = false }
        do {
            let backup = try await Task.detached {
                try Backups.read(url)
            }.value
            let current = try await session.readConfigText(operation: operation)
            let found = Restore.compare(backup: backup, current: current)
            guard session.isCurrent(operation),
                  session.activeRouterID == operation.routerID else {
                alert = AlertPayload(
                    title: "Роутер переключён",
                    message: "Сверка относилась к другому роутеру и была отменена. Выбери снимок и повтори её.",
                    isError: false)
                return
            }
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
            alert = AlertPayload(title: "Не удалось сверить", message: session.describe(error))
        }
    }

    private func apply(_ plan: Plan, dryRun: Bool) async {
        do {
            let result = try await session.apply(plan: plan, dryRun: dryRun,
                                                 saveConfig: Store.shared.settings.saveConfigAfterApply)
            if result.applied { outcome = result }
        } catch {
            alert = AlertPayload(title: "Возврат не удался", message: session.describe(error))
        }
    }

    private func snapshot() async {
        let operation = session.beginOperation()
        let profile = session.router
        do {
            let text = try await session.readConfigText(operation: operation)
            let url = Backups.saveRunningConfig(host: profile.host, text: text,
                                                keep: Store.shared.settings.keepBackups)
            guard let url else {
                throw TransportError(
                    "Защищённая копия не создана.",
                    hint: "Проверь доступ приложения к связке ключей и свободное место на диске.")
            }
            log(.ok, "Защищённая копия конфигурации: \(url.lastPathComponent)")
            reload()
            if session.isCurrent(operation) { select(url) }
        } catch {
            alert = AlertPayload(title: "Не удалось снять копию", message: session.describe(error))
        }
    }
}

/// Что именно вернётся, до того как собран план команд.
struct RestorePreview: View {
    let difference: Restore.Difference
    let snapshot: String
    var onBuild: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(icon: "clock.arrow.circlepath", title: "Возврат к резервной копии",
                       subtitle: snapshot)
                .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        MetricTile(value: String(difference.missingDomainCount),
                                   label: "Вернуть доменов", icon: "arrow.uturn.backward",
                                   tint: Palette.success)
                        MetricTile(value: String(difference.extraDomainCount),
                                   label: "Убрать доменов", icon: "minus.circle",
                                   tint: Palette.danger)
                        MetricTile(value: String(difference.missingGroups.count),
                                   label: "Создать списков", icon: "folder.badge.plus",
                                   tint: Palette.accent)
                        MetricTile(value: String(difference.extraGroups.count),
                                   label: "Удалить списков", icon: "folder.badge.minus",
                                   tint: Palette.warning)
                    }

                    section("Списки появятся заново", difference.missingGroups.map {
                        "\($0.ident) · \($0.descriptionText) · \(Format.domains($0.includes.count))"
                    }, tint: Palette.accent)

                    section("Списки будут удалены", difference.extraGroups.map {
                        "\($0.ident) · \($0.descriptionText) · \(Format.domains($0.includes.count))"
                    }, tint: Palette.warning)

                    section("Маршруты списков вернутся", difference.missingRouteLines,
                            tint: Palette.success)
                    section("Маршруты списков снимутся", difference.extraRouteLines,
                            tint: Palette.danger)
                    section("Статические маршруты вернутся",
                            difference.missingRoutes.map(\.command), tint: Palette.success)
                    section("Статические маршруты снимутся",
                            difference.extraRoutes.map(\.command), tint: Palette.danger)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                        Text("Возвращается только то, чем управляет приложение: списки FQDN, "
                             + "их маршруты и статические маршруты. Wi-Fi, NAT, межсетевой экран "
                             + "и прочее из снимка не трогаются.")
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

    private var cancelButton: some View {
        Button("Отмена", action: onCancel)
            .buttonStyle(SubtleButtonStyle())
            .keyboardShortcut(.cancelAction)
    }

    private var buildButton: some View {
        Button("Собрать план") { onBuild() }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
    }

    private var summaryText: some View {
        Text(difference.summary.joined(separator: " · "))
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
