import SwiftUI

/// Сравнение списков FQDN двух роутеров. Соединения при переключении больше
/// не рвутся, поэтому оба состояния доступны одновременно — и видно, чем
/// роутеры расходятся, вручную такое не сверить.
struct CompareView: View {
    @EnvironmentObject private var session: RouterSession
    @ObservedObject private var store = Store.shared
    @Binding var alert: AlertPayload?
    @Binding var section: AppSection

    @State private var referenceID: UUID?
    @State private var plan: Plan?
    @State private var outcome: ApplyOutcome?

    private var candidates: [RouterProfile] {
        let read = session.routersWithState()
        return store.routers.filter { $0.id != session.router.id && read.contains($0.id) }
    }

    private var reference: RouterProfile? {
        guard let referenceID else { return candidates.first }
        return candidates.first { $0.id == referenceID } ?? candidates.first
    }

    private var comparison: Comparison? {
        guard let reference,
              let theirs = session.readState(for: reference.id),
              let ours = session.state else { return nil }
        return Comparison(reference: reference, theirs: theirs, ours: ours)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let progress = session.progress { ProgressBanner(info: progress) }

                if session.state == nil {
                    notRead
                } else if candidates.isEmpty {
                    needSecondRouter
                } else if let comparison {
                    picker(comparison)
                    summary(comparison)
                    details(comparison)
                }
            }
            .padding(20)
        }
        .sheet(item: Binding(get: { plan.map(PlanBox.init) }, set: { plan = $0?.plan })) { box in
            PlanSheet(plan: box.plan, applyTitle: "Перенести") { dryRun in
                plan = nil
                Task { await apply(box.plan, dryRun: dryRun) }
            } onCancel: { plan = nil }
        }
        .sheet(item: Binding(get: { outcome.map(OutcomeBox.init) }, set: { outcome = $0?.outcome })) { box in
            OutcomeSheet(title: "Перенос доменов", outcome: box.outcome) { outcome = nil }
        }
    }

    // MARK: - Состояния

    private var notRead: some View {
        EmptyHint(icon: "bolt.horizontal.circle", title: "Активный роутер не прочитан",
                  message: "Подключись к нему и нажми «Обновить».")
            .card(padding: 24)
    }

    private var needSecondRouter: some View {
        VStack(spacing: 14) {
            EmptyHint(icon: "arrow.left.arrow.right", title: "Не с чем сравнивать",
                      message: "Переключись на другой роутер, прочитай его конфигурацию и "
                             + "вернись сюда. Связь при переключении не рвётся, так что оба "
                             + "останутся на линии.")
            Button("К списку роутеров") { section = .routers }
                .buttonStyle(SubtleButtonStyle())
        }
        .card(padding: 24)
    }

    // MARK: - Содержимое

    private func picker(_ comparison: Comparison) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeader(icon: "arrow.left.arrow.right", title: "Сравнение роутеров",
                           subtitle: "Что есть у эталонного, но отсутствует на активном")
                Spacer()
                Picker("", selection: Binding(
                    get: { reference?.id ?? candidates.first?.id },
                    set: { referenceID = $0 })) {
                    ForEach(candidates) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            HStack(spacing: 10) {
                side(name: comparison.reference.name, role: "эталон",
                     lists: comparison.theirs.groups.count,
                     domains: comparison.theirs.totalDomains, tint: Palette.accent)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                side(name: session.router.name, role: "активный",
                     lists: comparison.ours.groups.count,
                     domains: comparison.ours.totalDomains, tint: Palette.success)
            }
        }
        .card()
    }

    private func side(name: String, role: String, lists: Int, domains: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 13, weight: .semibold))
                StatusPill(text: role, tint: tint)
            }
            Text("\(Format.lists(lists)) · \(Format.domains(domains))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .inset(cornerRadius: 11)
    }

    private func summary(_ comparison: Comparison) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                MetricTile(value: String(comparison.missingHere.count),
                           label: "Нет на активном", icon: "arrow.down.circle",
                           tint: comparison.missingHere.isEmpty ? Palette.success : Palette.warning)
                MetricTile(value: String(comparison.extraHere.count),
                           label: "Только на активном", icon: "arrow.up.circle")
                MetricTile(value: String(comparison.shared),
                           label: "Совпадает", icon: "equal.circle", tint: Palette.success)
            }

            if comparison.missingHere.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.success)
                    Text("На «\(session.router.name)» есть всё, что и на «\(comparison.reference.name)».")
                        .font(.system(size: 12))
                }
            } else {
                HStack(spacing: 10) {
                    Button("Перенести недостающее сюда") { buildPlan(comparison) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(session.progress != nil)
                    Text("Домены добавятся в списки с тем же описанием. "
                         + "Ничего не удаляется.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    private func details(_ comparison: Comparison) -> some View {
        HStack(alignment: .top, spacing: 16) {
            domainList(title: "Нет на «\(session.router.name)»",
                       icon: "arrow.down.circle", tint: Palette.warning,
                       domains: comparison.missingHere)
            domainList(title: "Только на «\(session.router.name)»",
                       icon: "arrow.up.circle", tint: Palette.accent,
                       domains: comparison.extraHere)
        }
    }

    private func domainList(title: String, icon: String, tint: Color, domains: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: icon, title: title,
                       subtitle: domains.isEmpty ? "пусто" : Format.domains(domains.count), tint: tint)

            if domains.isEmpty {
                Text("Расхождений нет")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(domains.prefix(300), id: \.self) { domain in
                            Text(domain)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if domains.count > 300 {
                            Text("… и ещё \(domains.count - 300)")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 320)
                .inset()
            }
        }
        .card()
    }

    // MARK: - Действия

    private func buildPlan(_ comparison: Comparison) {
        var reserved = Set(comparison.ours.groups.keys)
        let built = Planner.planSync(reference: comparison.theirs.groups,
                                     current: comparison.ours.groups,
                                     chunkSize: store.settings.chunkSize,
                                     reservedIDs: &reserved)
        if built.isEmpty {
            alert = AlertPayload(title: "Переносить нечего",
                                 message: "Все домены эталонного роутера уже есть здесь.",
                                 isError: false)
            return
        }
        plan = built
    }

    private func apply(_ plan: Plan, dryRun: Bool) async {
        do {
            let result = try await session.apply(plan: plan, dryRun: dryRun,
                                                 saveConfig: store.settings.saveConfigAfterApply)
            if result.applied { outcome = result }
        } catch {
            alert = AlertPayload(title: "Не удалось перенести", message: session.describe(error))
        }
    }
}

/// Разница между двумя прочитанными роутерами.
private struct Comparison {
    let reference: RouterProfile
    let theirs: RouterState
    let ours: RouterState

    var missingHere: [String] {
        let mine = ours.groups.values.reduce(into: Set<String>()) { $0.formUnion($1.includes) }
        let other = theirs.groups.values.reduce(into: Set<String>()) { $0.formUnion($1.includes) }
        return other.subtracting(mine).sorted()
    }

    var extraHere: [String] {
        let mine = ours.groups.values.reduce(into: Set<String>()) { $0.formUnion($1.includes) }
        let other = theirs.groups.values.reduce(into: Set<String>()) { $0.formUnion($1.includes) }
        return mine.subtracting(other).sorted()
    }

    var shared: Int {
        let mine = ours.groups.values.reduce(into: Set<String>()) { $0.formUnion($1.includes) }
        let other = theirs.groups.values.reduce(into: Set<String>()) { $0.formUnion($1.includes) }
        return mine.intersection(other).count
    }
}
