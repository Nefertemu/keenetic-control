import SwiftUI

/// Ping-Check: профили проверки связи и их привязка к интерфейсам.
/// В веб-панели Keenetic этого нет вовсе — только через командную строку.
struct PingCheckView: View {
    @EnvironmentObject private var session: RouterSession
    @ObservedObject private var store = Store.shared
    @Binding var alert: AlertPayload?

    /// Профиль и признак новизны — одним значением: раздельные состояния
    /// расходились, и диалог открывался с заблокированным именем.
    private struct Editing: Identifiable {
        let id = UUID()
        var profile: PingCheckProfile
        var isNew: Bool
    }

    @State private var editing: Editing?
    @State private var confirmDelete: PingCheckProfile?
    @State private var pending: [String: PingCheckBinding] = [:]
    @State private var plan: Plan?
    @State private var outcome: ApplyOutcome?

    private var profiles: [PingCheckProfile] { session.state?.pingCheckProfiles ?? [] }

    /// Интерфейсы, для которых проверка связи имеет смысл.
    private var interfaces: [KeeneticInterface] {
        (session.state?.candidates ?? []).filter { !$0.ident.hasPrefix("Loopback") }
    }

    private func binding(for ident: String) -> PingCheckBinding {
        pending[ident]
            ?? session.state?.pingCheckBindings[ident]
            ?? PingCheckBinding(profile: "", restart: false)
    }

    private func users(of profile: PingCheckProfile) -> [String] {
        (session.state?.pingCheckBindings ?? [:])
            .filter { $0.value.profile == profile.name }
            .keys.sorted()
    }

    private func saved(for ident: String) -> PingCheckBinding {
        session.state?.pingCheckBindings[ident] ?? PingCheckBinding(profile: "", restart: false)
    }

    private var changes: [String: PingCheckBinding] {
        var result: [String: PingCheckBinding] = [:]
        for (ident, wanted) in pending where wanted != saved(for: ident) {
            result[ident] = wanted
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let progress = session.progress { ProgressBanner(info: progress) }

                    if session.state == nil {
                        EmptyHint(icon: "bolt.horizontal.circle", title: "Роутер не прочитан",
                                  message: "Подключись и нажми «Обновить».")
                            .card(padding: 24)
                    } else {
                        profilesCard
                        assignmentCard
                    }
                }
                .padding(.top, 4)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .id("ping-check-top")
            }
            // При переходе из другой длинной вкладки macOS мог сохранить
            // старую позицию ScrollView, из-за чего шапка Ping‑Check
            // оказывалась обрезанной под toolbar. Всегда начинаем экран с
            // собственной шапки, но не вмешиваемся в обычную прокрутку.
            .onAppear {
                // Ждём один layout pass: на macOS вызов прямо из onAppear
                // иногда происходит до того, как ScrollView зарегистрировал
                // цель, и старый offset тогда не сбрасывается.
                DispatchQueue.main.async {
                    proxy.scrollTo("ping-check-top", anchor: .top)
                }
            }
            .onChange(of: session.router.id) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("ping-check-top", anchor: .top)
                }
            }
        }
        .onChange(of: session.router.id) { _, _ in
            // Иначе правки, набранные на одном роутере, уехали бы
            // на другой — и применились бы там.
            pending.removeAll()
        }
        .sheet(item: $editing) { item in
            PingCheckEditor(profile: item.profile, isNew: item.isNew) { edited in
                if buildSavePlan(edited, isNew: item.isNew) {
                    editing = nil
                }
            } onCancel: { editing = nil }
        }
        .sheet(item: Binding(get: { plan.map(PlanBox.init) }, set: { plan = $0?.plan })) { box in
            PlanSheet(plan: box.plan, state: session.state) { dryRun in
                plan = nil
                Task { await apply(box.plan, dryRun: dryRun) }
            } onCancel: { plan = nil }
        }
        .sheet(item: Binding(get: { outcome.map(OutcomeBox.init) }, set: { outcome = $0?.outcome })) { box in
            OutcomeSheet(title: "Ping-Check", outcome: box.outcome) { outcome = nil }
        }
        .confirmationDialog("Удалить профиль «\(confirmDelete?.name ?? "")»?",
                            isPresented: Binding(get: { confirmDelete != nil },
                                                 set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let victim = confirmDelete {
                    plan = PingCheckParser.planDelete(victim, usedBy: users(of: victim))
                        .forRouter(session.router)
                        .forRouter(session.router)
                }
                confirmDelete = nil
            }
            Button("Отмена", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("Сначала профиль снимется с интерфейсов, которые его используют.")
        }
    }

    // MARK: - Профили

    private var profilesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    profilesHeader
                    Spacer()
                    addProfileButton
                }
                .frame(minWidth: 600)

                VStack(alignment: .leading, spacing: 10) {
                    profilesHeader
                    addProfileButton
                }
            }

            if profiles.isEmpty {
                EmptyHint(icon: "waveform.path", title: "Профилей нет",
                          message: "Создай профиль и назначь его на туннель — "
                                 + "роутер начнёт следить за связью и переключать маршруты.")
            } else {
                VStack(spacing: 0) {
                    ForEach(profiles) { profile in
                        profileRow(profile)
                        if profile.id != profiles.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .inset()
            }
        }
        .card()
    }

    private func profileRow(_ profile: PingCheckProfile) -> some View {
        let assigned = users(of: profile)

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 11) {
                profileIdentity(profile)
                Spacer(minLength: 8)
                profileAssignment(assigned)
                profileActions(profile)
            }
            .frame(minWidth: 650)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    profileIdentity(profile)
                    Spacer(minLength: 4)
                    profileActions(profile)
                }
                profileAssignment(assigned)
            }
        }
        .padding(.vertical, 9)
    }

    private var profilesHeader: some View {
        CardHeader(icon: "waveform.path.ecg", title: "Профили Ping-Check",
                   subtitle: "Роутер проверяет связь и гасит интерфейс, если узел не отвечает")
    }

    private var addProfileButton: some View {
        Button("Добавить профиль") {
            // Пустые поля роутер заполнит своими значениями по умолчанию.
            editing = Editing(profile: PingCheckProfile(name: "", host: "", mode: .icmp,
                                                        updateInterval: 10),
                              isNew: true)
        }
        .buttonStyle(PrimaryButtonStyle())
    }

    private func profileIdentity(_ profile: PingCheckProfile) -> some View {
        HStack(spacing: 11) {
            Image(systemName: profile.isBuiltIn ? "lock.circle" : "waveform.path.ecg")
                .font(.system(size: 14))
                .foregroundStyle(profile.isBuiltIn ? Color.secondary : Palette.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(profile.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if profile.isBuiltIn { StatusPill(text: "встроенный", tint: .secondary) }
                }
                Text(profile.isBuiltIn ? "Настраивается самим роутером" : profile.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(profile.isBuiltIn ? "Профиль встроен в прошивку" : profile.summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func profileAssignment(_ assigned: [String]) -> some View {
        Group {
            if assigned.isEmpty {
                StatusPill(text: "не используется", tint: Palette.warning)
            } else {
                // Само имя полезнее числа: с одним-двумя туннелями видно сразу,
                // а расшифровка целиком всё равно остаётся в подсказке.
                StatusPill(text: assigned.count <= 2
                             ? (session.state?.targetSummary(assigned) ?? assigned.joined(separator: ", "))
                             : Format.plural(assigned.count, "интерфейс", "интерфейса", "интерфейсов"),
                           tint: Palette.success)
                    .help(session.state?.targetTooltip(assigned) ?? assigned.joined(separator: "\n"))
            }
        }
    }

    private func profileActions(_ profile: PingCheckProfile) -> some View {
        HStack(spacing: 8) {
            Button("Изменить") {
                editing = Editing(profile: profile, isNew: false)
            }
            .buttonStyle(SubtleButtonStyle())
            .disabled(profile.isBuiltIn)

            Button {
                confirmDelete = profile
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(profile.isBuiltIn ? Color.secondary : Palette.danger)
            .disabled(profile.isBuiltIn)
        }
    }

    // MARK: - Привязка к интерфейсам

    private var assignmentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    assignmentHeader
                    Spacer()
                    assignmentActions
                }
                .frame(minWidth: 700)

                VStack(alignment: .leading, spacing: 8) {
                    assignmentHeader
                    assignmentActions
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("Интерфейс").frame(width: 250, alignment: .leading)
                        Text("Профиль").frame(width: 190, alignment: .leading)
                        Text("Перезапуск").frame(width: 110, alignment: .leading)
                        Text("Сейчас").frame(width: 150, alignment: .leading)
                        Spacer()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)

                    Divider()

                    ForEach(interfaces) { item in
                        interfaceRow(item)
                        if item.id != interfaces.last?.id { Divider() }
                    }
                }
                .frame(minWidth: 760, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .inset()
        }
        .card()
    }

    private var assignmentHeader: some View {
        CardHeader(icon: "point.3.connected.trianglepath.dotted",
                   title: "Назначение на интерфейсы",
                   subtitle: "«Перезапуск» поднимает туннель заново, когда связь пропала")
    }

    @ViewBuilder
    private var assignmentActions: some View {
        HStack(spacing: 8) {
            if !changes.isEmpty {
                Button("Отменить правки") { pending.removeAll() }
                    .buttonStyle(SubtleButtonStyle())
            }
            Button(changes.isEmpty ? "Изменений нет" : "Применить (\(changes.count))") {
                buildAssignPlan()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(changes.isEmpty || session.progress != nil)
        }
    }

    private func interfaceRow(_ item: KeeneticInterface) -> some View {
        let current = binding(for: item.ident)
        let dirty = current != saved(for: item.ident)

        return HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(item.isUp ? Palette.success : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.shortName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !item.descriptionText.isEmpty {
                        Text(item.ident)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 250, alignment: .leading)
            .help(item.displayName)

            Picker("", selection: Binding(
                get: { current.profile },
                set: { pending[item.ident] = PingCheckBinding(profile: $0, restart: current.restart) })) {
                Text("— нет —").tag("")
                ForEach(profiles) { Text($0.name).tag($0.name) }
            }
            .labelsHidden()
            .frame(width: 190)

            Toggle("", isOn: Binding(
                get: { current.restart },
                set: { pending[item.ident] = PingCheckBinding(profile: current.profile, restart: $0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(current.profile.isEmpty)
                .frame(width: 110, alignment: .leading)

            // Что роутер думает о проверке прямо сейчас — назначения мало,
            // важно знать, проходит она или падает.
            let check = session.state?.pingCheck(for: item.ident) ?? .notConfigured
            Group {
                if check.isKnown {
                    LiveStateLine(check: check, handshake: nil, online: false)
                } else {
                    Text("—").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 150, alignment: .leading)
            .help(check.explanation)

            if dirty { StatusPill(text: "изменено", tint: Palette.warning) }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Действия

    @discardableResult
    private func buildSavePlan(_ profile: PingCheckProfile, isNew: Bool) -> Bool {
        var cleaned = profile
        cleaned.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try PingCheckProfile.validate(cleaned)
        } catch {
            alert = AlertPayload(title: "Профиль не сохранён",
                                 message: (error as? TransportError)?.message ?? error.localizedDescription)
            return false
        }
        let duplicate = profiles.first {
            $0.name.caseInsensitiveCompare(cleaned.name) == .orderedSame
        }
        if isNew, let duplicate {
            alert = AlertPayload(
                title: "Такой профиль уже есть",
                message: "Профиль «\(duplicate.name)» уже создан. Выбери другое имя или измени существующий.",
                isError: false)
            return false
        }
        let existing = isNew ? nil : profiles.first {
            $0.name.caseInsensitiveCompare(cleaned.name) == .orderedSame && !$0.isBuiltIn
        }
        let candidate = PingCheckParser.planSave(cleaned, existing: existing)
        guard !candidate.isEmpty else { return true }
        plan = candidate.forRouter(session.router)
        return true
    }

    private func buildAssignPlan() {
        let merged = Planner.merge(title: "Ping-Check: назначение на интерфейсы",
                                   plans: changes.map { interface, wanted in
            PingCheckParser.planAssign(
                interface: interface,
                profile: wanted.profile.isEmpty ? nil : wanted.profile,
                restart: wanted.restart,
                current: session.state?.pingCheckBindings[interface])
        })
        if merged.isEmpty {
            pending.removeAll()
            return
        }
        plan = merged.forRouter(session.router)
    }

    private func apply(_ plan: Plan, dryRun: Bool) async {
        do {
            let result = try await session.apply(plan: plan, dryRun: dryRun,
                                                 saveConfig: store.settings.saveConfigAfterApply)
            if result.applied {
                outcome = result
                pending.removeAll()
            }
        } catch {
            alert = AlertPayload(title: "Не удалось применить", message: session.describe(error))
        }
    }
}

// MARK: - Редактор профиля

struct PingCheckEditor: View {
    @State var profile: PingCheckProfile
    private let original: PingCheckProfile
    let isNew: Bool
    var onSave: (PingCheckProfile) -> Void
    var onCancel: () -> Void

    init(profile: PingCheckProfile, isNew: Bool,
         onSave: @escaping (PingCheckProfile) -> Void,
         onCancel: @escaping () -> Void) {
        _profile = State(initialValue: profile)
        original = profile
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var hasChanges: Bool {
        isNew || !profile.isSemanticallyEqual(to: original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(icon: "waveform.path.ecg",
                       title: isNew ? "Новый профиль Ping-Check" : "Профиль «\(profile.name)»",
                       subtitle: "Роутер периодически проверяет узел и гасит интерфейс, если тот молчит")

            field("Имя профиля") {
                TextField("vpn", text: $profile.name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isNew)
            }

            field("Режим проверки") {
                Picker("", selection: $profile.mode) {
                    ForEach(PingCheckProfile.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(profile.mode.explanation)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            HStack(alignment: .top, spacing: 12) {
                if profile.mode.usesURI {
                    field("Адрес для проверки") {
                        TextField("https://example.com/", text: $profile.uri)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                } else {
                    field("Узел для проверки") {
                        TextField("google.com или 1.1.1.1", text: $profile.host)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                if profile.mode.usesPort {
                    field("Порт", width: 110) {
                        TextField("443", value: Binding(get: { profile.port ?? 443 },
                                                        set: { profile.port = $0 }), format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                number("Интервал проверки, с", $profile.updateInterval, placeholder: 10,
                       hint: "От 3 до 3600.")
                number("Тайм-аут ответа, с", $profile.timeout, placeholder: 2,
                       hint: "От 1 до 10. Пусто — роутер возьмёт 2.")
                number("Отказов до отключения", $profile.maxFails, placeholder: 5,
                       hint: "От 1 до 10. Пусто — роутер возьмёт 5.")
                number("Успехов до подъёма", $profile.minSuccess, placeholder: 5,
                       hint: "От 1 до 10. Пусто — роутер возьмёт 5.")
            }

            Toggle(isOn: $profile.powerCycle) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Перезапускать питание USB-модема").font(.system(size: 12))
                    Text("Роутер включает это сам; имеет смысл только для USB-модемов.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }

            HStack {
                Button("Отмена", action: onCancel)
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Создать" : "Сохранить") {
                    var cleaned = profile
                    cleaned.name = cleaned.name.trimmingCharacters(in: .whitespaces)
                    cleaned.host = cleaned.host.trimmingCharacters(in: .whitespaces)
                    onSave(cleaned)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges)
            }
        }
        .padding(22)
        .frame(minWidth: 460, idealWidth: 580, maxWidth: 580)
        .background(Palette.surface)
    }

    private func number(_ title: String, _ value: Binding<Int?>,
                        placeholder: Int, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(String(placeholder), value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = $0 }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                if value.wrappedValue != nil {
                    Button {
                        value.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Не задавать — оставить решение роутеру")
                }
                Spacer()
            }
            Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func field<Content: View>(_ title: String, width: CGFloat? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
        .frame(width: width)
    }
}
