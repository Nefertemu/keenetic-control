import AppKit
import SwiftUI

/// Представление отдельно от сетевой операции: один и тот же экран можно
/// проверить на длинных ответах и ошибках без доступа к роутеру.
struct DomainListUpdateCard: View {
    var isRunning: Bool
    var phase: String
    var completed: Int
    var total: Int
    var report: DomainListUpdateReport?
    var isDisabled: Bool
    var otherRouterName: String?
    var onUpdate: () -> Void
    @State private var detailsExpanded: Bool

    init(isRunning: Bool = false, phase: String = "", completed: Int = 0,
         total: Int = 0, report: DomainListUpdateReport? = nil,
         isDisabled: Bool = false, otherRouterName: String? = nil,
         detailsExpanded: Bool = false, onUpdate: @escaping () -> Void = {}) {
        self.isRunning = isRunning
        self.phase = phase
        self.completed = completed
        self.total = total
        self.report = report
        self.isDisabled = isDisabled
        self.otherRouterName = otherRouterName
        self.onUpdate = onUpdate
        _detailsExpanded = State(initialValue: detailsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 20) {
                    introduction
                    updateButton
                }
                .frame(minWidth: 560)
                VStack(alignment: .leading, spacing: 10) {
                    introduction
                    updateButton
                }
            }

            if isRunning {
                progress
            } else if let otherRouterName {
                Label("Обновляются списки: \(otherRouterName)", systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(otherRouterName)
            } else if let report {
                result(report)
            } else {
                Text("Части до 300 записей создаются автоматически с теми же маршрутами. Списки, созданные вручную, сохраняются.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // AppKit запрашивает минимальный размер с почти нулевой шириной.
        // Без нижней границы многострочное пояснение превращается в сотни
        // строк и поднимает минимальную высоту всего окна.
        .frame(minWidth: 320, alignment: .leading)
        .card(padding: 14)
        .onChange(of: report?.finishedAt) { _, _ in
            detailsExpanded = report.map(hasIssues) ?? false
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Обновление установленных списков", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text("Проверить источники, добавить новые записи и убрать исчезнувшие — одним нажатием.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help("Проверить источники, добавить новые записи и убрать исчезнувшие — одним нажатием.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var updateButton: some View {
        Button(action: onUpdate) {
            Label(isRunning ? "Обновление…" : "Обновить списки",
                  systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isRunning || isDisabled || otherRouterName != nil)
        .help("Загрузить свежие версии всех источников, уже используемых на этом роутере, и применить изменения.")
        .accessibilityIdentifier("domain-lists.update")
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text(phase.isEmpty ? "Подготовка обновления…" : phase)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .help(phase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if total > 0 {
                    Text("источники: \(min(completed, total)) / \(total)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            if total > 0, completed < total {
                ProgressView(value: Double(min(max(completed, 0), total)), total: Double(total))
                    .tint(Palette.accent)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func result(_ report: DomainListUpdateReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(summary(report), systemImage: hasIssues(report) ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hasIssues(report) ? Palette.warning : Palette.success)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(report.finishedAt, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            let changed = report.results.filter { $0.status == .updated }
            if !changed.isEmpty {
                let added = changed.reduce(0) { $0 + $1.added }
                let removed = changed.reduce(0) { $0 + $1.removed }
                let parts = changed.reduce(0) { $0 + $1.createdParts }
                Text("+\(added) добавлено · −\(removed) удалено" + (parts > 0 ? " · новых частей: \(parts)" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !report.results.isEmpty || report.error != nil || report.backupURL != nil {
                let resultHeight = min(110, CGFloat(report.results.count * 50 + (report.error == nil ? 0 : 70)))
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button {
                        detailsExpanded.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: detailsExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Подробности" + (report.results.isEmpty ? "" : " · источников: \(report.results.count)"))
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(report.results.isEmpty && report.error == nil)
                    .accessibilityValue(detailsExpanded ? "Развернуто" : "Свернуто")
                    Spacer(minLength: 0)
                    if let backupURL = report.backupURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([backupURL])
                        } label: {
                            Label("Резервная копия сохранена", systemImage: "externaldrive.badge.checkmark")
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                        .fixedSize()
                        .help("Показать копию конфигурации перед обновлением")
                    }
                }
                if detailsExpanded, resultHeight > 0 {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 9) {
                            if let error = report.error, !error.isEmpty {
                                Text(error)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            ForEach(report.results) { source in
                                sourceResult(source)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.trailing, 8)
                    }
                    .frame(minHeight: min(80, resultHeight), idealHeight: resultHeight, maxHeight: resultHeight)
                    .clipped()
                }
            }
        }
        .padding(.top, 2)
    }

    private func sourceResult(_ source: DomainSourceUpdateResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: source.status == .updated || source.status == .unchanged
                  ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(source.status == .updated || source.status == .unchanged
                                 ? Palette.success : Palette.warning)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(source.spec.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .help(source.spec.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(statusTitle(source))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if let message = source.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else if source.status == .updated {
                    Text("+\(source.added) добавлено · −\(source.removed) удалено"
                         + (source.createdParts > 0 ? " · новых частей: \(source.createdParts)" : ""))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func hasIssues(_ report: DomainListUpdateReport) -> Bool {
        report.error != nil || report.cancelled || report.results.contains {
            $0.status == .skipped || $0.status == .needsAttention
        }
    }

    private func summary(_ report: DomainListUpdateReport) -> String {
        if report.cancelled { return "Обновление прервано" }
        if hasIssues(report) {
            return report.results.contains { $0.status == .updated }
                ? "Обновлено частично" : "Обновление требует внимания"
        }
        if report.results.isEmpty { return "Установленных источников не найдено" }
        return report.results.contains { $0.status == .updated } ? "Списки обновлены" : "Списки актуальны"
    }

    private func statusTitle(_ source: DomainSourceUpdateResult) -> String {
        switch source.status {
        case .updated: return "Обновлён"
        case .unchanged: return "Без изменений"
        case .skipped: return "Пропущен"
        case .needsAttention: return "Требует внимания"
        }
    }
}

/// Состояние живёт в сессии и не теряется при переходе между вкладками.
struct DomainListUpdateSection: View {
    @ObservedObject var session: RouterSession
    @ObservedObject var updater: DomainListUpdateController
    @ObservedObject private var store = Store.shared

    init(session: RouterSession) {
        self.session = session
        self.updater = session.domainListUpdater
    }

    var body: some View {
        let belongsToRouter = updater.owner == RouterPresentationContext(session.router)
        DomainListUpdateCard(
            isRunning: updater.isRunning && belongsToRouter,
            phase: belongsToRouter ? updater.phase : "",
            completed: belongsToRouter ? updater.completed : 0,
            total: belongsToRouter ? updater.total : 0,
            report: belongsToRouter ? updater.report : nil,
            isDisabled: updater.isRunning || session.isBusy(session.router.id),
            otherRouterName: updater.isRunning && !belongsToRouter ? updater.routerName : nil
        ) {
            let catalog = store.allSources
            let settings = store.settings
            let context = RouterPresentationContext(session.router)
            Task {
                guard RouterPresentationContext(session.router) == context else { return }
                await updater.update(session: session, catalog: catalog,
                                     chunkSize: settings.chunkSize,
                                     saveConfig: settings.saveConfigAfterApply)
            }
        }
    }
}
