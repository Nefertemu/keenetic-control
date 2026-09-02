import AppKit
import SwiftUI

/// Единый предпросмотр перед отправкой чего-либо на роутер.
/// Ни одна операция в приложении не идёт мимо этого экрана.
struct PlanSheet: View {
    let plan: Plan
    var applyTitle: String = "Применить"
    /// Текущее состояние роутера — чтобы показать не только команды, но и
    /// во что они превратят конфигурацию.
    var state: RouterState?
    var onApply: (_ dryRun: Bool) -> Void
    var onCancel: () -> Void

    @State private var showAllCommands = false
    @State private var saveError: String?

    private var visibleCommands: [String] {
        showAllCommands ? plan.commands : Array(plan.commands.prefix(60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !plan.summary.isEmpty { summaryTiles }
                    if !plan.notes.isEmpty { notes }
                    if !changes.isEmpty { changesCard }
                    commands
                }
                .padding(20)
            }
            .background(Palette.canvas)

            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 760, maxWidth: 760,
               minHeight: 480, idealHeight: 620, maxHeight: 620)
        .background(Palette.surface)
        .alert("Не удалось сохранить план", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("Понятно", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Palette.accent.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title).font(.system(size: 15, weight: .semibold))
                Text("Будет отправлено \(Format.commands(plan.commands.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }

    private var changes: [PlanChangeRow] {
        plan.changes(against: state).filter { $0.domainsChanged || $0.routesChanged
                                              || $0.isNew || $0.isDeleted }
    }

    /// «Было → станет» по каждому списку. По голым командам CLI посчитать
    /// это можно, но никто не станет — а именно эта разница и есть то,
    /// ради чего план открывают.
    private var changesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "arrow.left.arrow.right", title: "Что изменится",
                       subtitle: "Состояние списков до и после применения")

            VStack(spacing: 0) {
                ForEach(changes) { row in
                    changeRow(row)
                    if row.id != changes.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .inset()
        }
        .card()
    }

    private func changeRow(_ row: PlanChangeRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if row.isNew { StatusPill(text: "новый", tint: Palette.accent) }
                if row.isDeleted { StatusPill(text: "удаляется", tint: Palette.danger) }
                Spacer(minLength: 6)
                Text(row.ident)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if row.domainsChanged {
                transition(title: "домены",
                           before: row.isNew ? "—" : String(row.domainsBefore),
                           after: row.isDeleted ? "—" : String(row.domainsAfter),
                           delta: row.domainsAfter - row.domainsBefore)
            }
            if row.routesChanged {
                transition(title: "маршруты",
                           before: row.routesBefore.isEmpty ? "нет"
                                 : (state?.targetSummary(row.routesBefore)
                                    ?? row.routesBefore.joined(separator: ", ")),
                           after: row.routesAfter.isEmpty ? "нет"
                                : (state?.targetSummary(row.routesAfter)
                                   ?? row.routesAfter.joined(separator: ", ")),
                           delta: nil)
            }
        }
        .padding(.vertical, 7)
    }

    private func transition(title: String, before: String, after: String,
                            delta: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)
            Text(before)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(after)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.accent)
                .lineLimit(1)
            if let delta, delta != 0 {
                Text(delta > 0 ? "+\(delta)" : String(delta))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(delta > 0 ? Palette.success : Palette.danger)
            }
            Spacer(minLength: 0)
        }
    }

    private var summaryTiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            if plan.addCount > 0 {
                MetricTile(value: String(plan.addCount), label: "Добавить доменов",
                           icon: "plus.circle", tint: Palette.success)
            }
            if plan.removeCount > 0 {
                MetricTile(value: String(plan.removeCount), label: "Удалить доменов",
                           icon: "minus.circle", tint: Palette.danger)
            }
            if !plan.createdGroups.isEmpty {
                MetricTile(value: String(plan.createdGroups.count), label: "Новых списков",
                           icon: "folder.badge.plus", tint: Palette.accent)
            }
            if !plan.routeTargets.isEmpty {
                MetricTile(value: String(plan.routeTargets.count), label: "Назначить маршрутов",
                           icon: "arrow.triangle.branch", tint: Palette.accent)
            }
            if !plan.unrouteTargets.isEmpty {
                MetricTile(value: String(plan.unrouteTargets.count), label: "Снять маршрутов",
                           icon: "arrow.uturn.left", tint: Palette.warning)
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "exclamationmark.bubble", title: "На что обратить внимание",
                       tint: Palette.warning)
            ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(Palette.warning)
                        .padding(.top, 6)
                    Text(note).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card()
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    commandsHeader
                    Spacer()
                    saveCommandsButton
                }
                .frame(minWidth: 500)

                VStack(alignment: .leading, spacing: 8) {
                    commandsHeader
                    saveCommandsButton
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(visibleCommands.enumerated()), id: \.offset) { index, command in
                    HStack(spacing: 8) {
                        Text(String(index + 1))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 34, alignment: .trailing)
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(command.hasPrefix("no ") ? Palette.danger : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 1)
                }

                if !showAllCommands, plan.commands.count > visibleCommands.count {
                    Button("Показать все \(plan.commands.count) команд") {
                        showAllCommands = true
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .padding(.top, 6)
                    .padding(.leading, 42)
                }
            }
            .padding(12)
            .inset()
        }
        .card()
    }

    private var commandsHeader: some View {
        CardHeader(icon: "terminal", title: "Команды Keenetic CLI",
                   subtitle: "Ровно то, что уйдёт на роутер")
    }

    private var saveCommandsButton: some View {
        Button("Сохранить в файл…") { saveCommands() }
            .buttonStyle(SubtleButtonStyle())
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                cancelButton
                Spacer()
                previewButton
                applyButton
            }
            .frame(minWidth: 500)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    cancelButton
                    Spacer(minLength: 0)
                    previewButton
                }
                applyButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(16)
    }

    private var cancelButton: some View {
        Button("Отмена", action: onCancel)
            .buttonStyle(SubtleButtonStyle())
            .keyboardShortcut(.cancelAction)
    }

    private var previewButton: some View {
        Button("Только предпросмотр") { onApply(true) }
            .buttonStyle(SubtleButtonStyle())
            .help("Ничего не отправлять на роутер — просто записать план в журнал")
    }

    private var applyButton: some View {
        Button(applyTitle) { onApply(false) }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(plan.isEmpty)
    }

    private func saveCommands() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "keenetic-plan_\(Format.stamp()).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (plan.commands.joined(separator: "\n") + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
            log(.ok, "План сохранён: \(url.path)")
        } catch {
            saveError = error.localizedDescription
            log(.error, "Не удалось сохранить план: \(error.localizedDescription)")
        }
    }
}

/// Итог применения — короткий и честный.
struct OutcomeSheet: View {
    let title: String
    let outcome: ApplyOutcome
    var onClose: () -> Void

    private var isClean: Bool { outcome.problems.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(isClean ? Palette.success : Palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isClean ? "Готово" : "Применено с замечаниями")
                        .font(.system(size: 16, weight: .semibold))
                    Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if outcome.elapsed > 0 {
                KeyValueRow(key: "Затрачено времени", value: Format.duration(outcome.elapsed))
            }
            if let backup = outcome.backupURL {
                KeyValueRow(key: "Резервная копия", value: backup.lastPathComponent, monospaced: true)
            }

            if !isClean {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Проверка нашла расхождения")
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(Array(outcome.problems.enumerated()), id: \.offset) { _, problem in
                        Text("• " + problem)
                            .font(.system(size: 11, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .inset()
            }

            HStack {
                if let backup = outcome.backupURL {
                    Button("Показать бэкап в Finder") {
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
