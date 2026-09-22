import AppKit
import SwiftUI

struct OperationHistoryView: View {
    @ObservedObject var session: RouterSession
    @ObservedObject var history: OperationHistoryStore
    @State private var query = ""
    @State private var onlyIssues = false
    @State private var selected: OperationHistoryRecord?
    @State private var confirmClear = false

    init(session: RouterSession) {
        self.session = session
        self.history = session.operationHistory
    }

    private var records: [OperationHistoryRecord] {
        history.records(for: session.router.id).filter {
            (!onlyIssues || $0.status.hasIssue)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    || $0.sources.contains { $0.title.localizedCaseInsensitiveContains(query) }
                    || $0.changes.contains { $0.title.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: "clock.arrow.circlepath", title: "История операций",
                       subtitle: "\(session.router.name) · последние 100 операций сохраняются после перезапуска")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { search; controls }.frame(minWidth: 630)
                VStack(alignment: .leading, spacing: 8) { search; controls }
            }
            if let error = history.persistenceError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if records.isEmpty {
                EmptyHint(icon: "clock", title: "Операций пока нет",
                          message: query.isEmpty && !onlyIssues
                            ? "Здесь появятся изменения списков, маршрутов и результаты восстановления."
                            : "Попробуй другой запрос или убери фильтр замечаний.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(records) { record in
                            Button { selected = record } label: { row(record) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("history.operation.\(record.id)")
                        }
                    }.padding(.bottom, 8)
                }
            }
        }
        .padding(20)
        .background(Palette.canvas)
        .onChange(of: session.router.id) { _, _ in selected = nil; confirmClear = false }
        .sheet(item: $selected) { record in
            OperationHistoryDetail(recordID: record.id, history: history) { selected = nil }
        }
        .confirmationDialog("Очистить историю «\(session.router.name)»?", isPresented: $confirmClear) {
            Button("Очистить историю", role: .destructive) { history.clear(routerID: session.router.id) }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Будут удалены завершённые записи. Выполняющиеся операции и резервные копии останутся.") }
    }

    private var search: some View {
        TextField("Поиск по операции, источнику или списку", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220, maxWidth: .infinity)
    }
    private var controls: some View {
        HStack(spacing: 12) {
            Toggle("С замечаниями", isOn: $onlyIssues).toggleStyle(.checkbox)
            Button("Очистить…") { confirmClear = true }
                .buttonStyle(SubtleButtonStyle())
                .disabled(!history.records(for: session.router.id).contains { $0.status != .running })
        }
    }

    private func row(_ record: OperationHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: record.status == .running ? "clock"
                      : record.status.hasIssue ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(record.status == .running ? Palette.accent
                                     : record.status.hasIssue ? Palette.warning : Palette.success)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(.system(size: 13, weight: .semibold))
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Text(record.startedAt, format: .dateTime.day().month().year().hour().minute())
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(record.status.title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(record.status.hasIssue ? Palette.warning : .secondary)
            if !record.changes.isEmpty {
                Text("+\(record.addedCount) записей · −\(record.removedCount) записей · списков: \(record.changes.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Команд: \(record.commandCount)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if record.status == .temporary {
                Text("На момент операции изменения не были сохранены после перезагрузки роутера.")
                    .font(.system(size: 11)).foregroundStyle(Palette.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

struct OperationHistoryDetail: View {
    let recordID: UUID
    @ObservedObject var history: OperationHistoryStore
    var onClose: () -> Void

    private var record: OperationHistoryRecord? { history.records.first { $0.id == recordID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let record {
                CardHeader(icon: "clock.arrow.circlepath", title: record.title,
                           subtitle: record.routerName + " · " + record.status.title)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(record.startedAt, format: .dateTime.day().month().year().hour().minute().second())
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if record.status == .temporary {
                            Label("Применено временно: на момент этой операции сохранение было отключено.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundStyle(Palette.warning)
                        }
                        ForEach(Array(record.problems.enumerated()), id: \.offset) { _, message in
                            Text(message).font(.system(size: 11)).foregroundStyle(Palette.warning)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        if [.running, .needsAttention, .failed, .interrupted].contains(record.status), !record.changes.isEmpty {
                            Label("Ниже — план изменений. Фактическое состояние не подтверждено полностью.", systemImage: "info.circle")
                                .font(.system(size: 12)).foregroundStyle(Palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(record.changes) { change in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(change.title).font(.system(size: 12, weight: .semibold))
                                Text(change.isDeleted ? "Список удалён" : change.isCreated ? "Создан новый список" : "Изменён список")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Text("Записей: \(change.beforeCount) → \(change.afterCount)")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                if change.routesBefore != change.routesAfter {
                                    Text("Маршруты: \(routeLabel(change.routesBefore)) → \(routeLabel(change.routesAfter))")
                                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                                }
                                if !change.added.isEmpty { entries("Добавлено", values: change.added) }
                                if !change.removed.isEmpty { entries("Удалено", values: change.removed) }
                            }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 12)
                        }
                        ForEach(record.sources) { source in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.title).font(.system(size: 12, weight: .semibold))
                                Text("Записей: \(source.entryCount) · версия \(source.digest.prefix(12))"
                                     + (source.fromCache ? " · из кэша" : ""))
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                if let date = source.fetchedAt {
                                    Text(date, format: .dateTime.day().month().year().hour().minute())
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Text(source.locations.joined(separator: "\n"))
                                    .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 12)
                        }
                        if !record.commands.isEmpty {
                            DisclosureGroup("Команды · \(record.commandCount)") {
                                Text(record.commands.joined(separator: "\n"))
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                if record.commandsTruncated {
                                    Text("Показаны первые \(record.commands.count) команд. Полный список изменений приведён выше.")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                }.clipped()
                HStack {
                    if let backup = record.backupURL {
                        if FileManager.default.fileExists(atPath: backup.path) {
                            Button("Показать резервную копию") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                                .buttonStyle(SubtleButtonStyle())
                        } else {
                            Text("Резервная копия перемещена или удалена")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Закрыть", action: onClose).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.cancelAction)
                }
            } else {
                Text("Запись больше не доступна.")
                Button("Закрыть", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 720, height: 620)
        .background(Palette.canvas)
    }

    private func routeLabel(_ values: [String]) -> String { values.isEmpty ? "не назначены" : values.joined(separator: " → ") }
    private func entries(_ title: String, values: [String]) -> some View {
        DisclosureGroup("\(title) · \(values.count)") {
            Text(values.joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}
