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
    /// Разница считается один раз на пару прочитанных конфигураций.
    /// Пока она была вычисляемым свойством, десятки тысяч доменов
    /// пересчитывались на каждую перерисовку — в том числе на каждый
    /// шаг индикатора выполнения.
    @State private var comparison: Comparison?

    private var candidates: [RouterProfile] {
        let read = session.routersWithState()
        return store.routers.filter { $0.id != session.router.id && read.contains($0.id) }
    }

    private var reference: RouterProfile? {
        guard let referenceID else { return candidates.first }
        return candidates.first { $0.id == referenceID } ?? candidates.first
    }

    /// Домены обоих роутеров прочитаны, а разницу ещё не посчитали.
    private var counting: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Сверяю списки…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .card()
    }

    /// Что должно измениться, чтобы пересчитать разницу.
    private var comparisonKey: String {
        guard let reference,
              let theirs = session.readState(for: reference.id),
              let ours = session.state else { return "" }
        return "\(reference.id)|\(ours.readAt.timeIntervalSince1970)"
             + "|\(theirs.readAt.timeIntervalSince1970)"
    }

    private func rebuildComparison() {
        guard let reference,
              let theirs = session.readState(for: reference.id),
              let ours = session.state else { comparison = nil; return }
        comparison = Comparison(reference: reference, theirs: theirs, ours: ours)
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
                } else {
                    counting
                }
            }
            .padding(20)
        }
        .task(id: comparisonKey) { rebuildComparison() }
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
            ViewThatFits(in: .horizontal) {
                HStack {
                    comparisonHeader
                    Spacer()
                    referencePicker
                }
                .frame(minWidth: 560)

                VStack(alignment: .leading, spacing: 10) {
                    comparisonHeader
                    referencePicker
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    referenceSide(comparison)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    activeSide(comparison)
                }
                .frame(minWidth: 520)

                VStack(spacing: 8) {
                    referenceSide(comparison)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    activeSide(comparison)
                }
            }
        }
        .card()
    }

    private var comparisonHeader: some View {
        CardHeader(icon: "arrow.left.arrow.right", title: "Сравнение роутеров",
                   subtitle: "Что есть у эталонного, но отсутствует на активном")
    }

    private var referencePicker: some View {
        Picker("", selection: Binding(
            get: { reference?.id ?? candidates.first?.id },
            set: { referenceID = $0 })) {
            ForEach(candidates) { Text($0.name).tag(Optional($0.id)) }
        }
        .labelsHidden()
        .frame(minWidth: 160, idealWidth: 190, maxWidth: 230)
    }

    private func referenceSide(_ comparison: Comparison) -> some View {
        side(name: comparison.reference.name, role: "эталон",
             lists: comparison.theirs.groups.count,
             domains: comparison.theirs.totalDomains, tint: Palette.accent)
    }

    private func activeSide(_ comparison: Comparison) -> some View {
        side(name: session.router.name, role: "активный",
             lists: comparison.ours.groups.count,
             domains: comparison.ours.totalDomains, tint: Palette.success)
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        transferButton(comparison)
                        transferExplanation
                    }
                    .frame(minWidth: 520)

                    VStack(alignment: .leading, spacing: 8) {
                        transferButton(comparison)
                        transferExplanation
                    }
                }
            }
        }
        .card()
    }

    private func transferButton(_ comparison: Comparison) -> some View {
        Button("Перенести недостающее сюда") { buildPlan(comparison) }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(session.progress != nil)
    }

    private var transferExplanation: some View {
        Text("Домены добавятся в списки с тем же описанием. Ничего не удаляется.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func details(_ comparison: Comparison) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                missingList(comparison)
                extraList(comparison)
            }
            .frame(minWidth: 640)

            VStack(alignment: .leading, spacing: 16) {
                missingList(comparison)
                extraList(comparison)
            }
        }
    }

    private func missingList(_ comparison: Comparison) -> some View {
        domainList(title: "Нет на «\(session.router.name)»",
                   icon: "arrow.down.circle", tint: Palette.warning,
                   domains: comparison.missingHere)
    }

    private func extraList(_ comparison: Comparison) -> some View {
        domainList(title: "Только на «\(session.router.name)»",
                   icon: "arrow.up.circle", tint: Palette.accent,
                   domains: comparison.extraHere)
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
        plan = built.forRouter(session.router)
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

/// Разница между двумя прочитанными роутерами. Считается один раз при
/// создании: тут тысячи доменов, и пересчёт на каждое обращение из body
/// заметно тормозил бы отрисовку.
private struct Comparison {
    let reference: RouterProfile
    let theirs: RouterState
    let ours: RouterState
    let missingHere: [String]
    let extraHere: [String]
    let shared: Int

    init(reference: RouterProfile, theirs: RouterState, ours: RouterState) {
        self.reference = reference
        self.theirs = theirs
        self.ours = ours

        let mine = ours.groups.values.reduce(into: Set<String>()) { $0.formUnion($1.includes) }
        let other = theirs.groups.values.reduce(into: Set<String>()) { $0.formUnion($1.includes) }
        missingHere = other.subtracting(mine).sorted()
        extraHere = mine.subtracting(other).sorted()
        shared = mine.intersection(other).count
    }
}
