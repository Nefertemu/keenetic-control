import AppKit
import SwiftUI

struct RoutersView: View {
    @EnvironmentObject private var session: RouterSession
    @ObservedObject private var store = Store.shared
    @Binding var alert: AlertPayload?

    @State private var editing: RouterProfile?
    @State private var confirmDelete: RouterProfile?
    /// Связку ключей дёргаем по разу на роутер, а не на каждую перерисовку:
    /// каждое обращение — потенциальный системный запрос доступа.
    /// nil — ещё не спрашивали: пока проверка идёт, писать «нет пароля»
    /// нельзя, это выглядит как поломка на ровном месте.
    @State private var havePassword: Set<UUID>?
    @ObservedObject private var updater = AutoUpdater.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                routers
                settings
                autoUpdate
                storage
            }
            .padding(20)
        }
        .sheet(item: $editing) { profile in
            RouterEditor(profile: profile) { updated, password in
                let activeBeforeSave = session.activeRouterID
                editing = nil
                if store.routers.contains(where: { $0.id == updated.id }) {
                    store.update(updated)
                } else {
                    store.add(updated)
                }
                // Профиль не обязательно активен: старый роутер мог
                // продолжать длинную операцию в фоне после переключения.
                // Инвалидируем его слот сразу, до возможного запроса связки
                // ключей, чтобы команды не ушли по прежнему адресу.
                session.profileDidChange(updated)
                Task {
                    if let password {
                        await Task.detached { updated.password = password }.value
                        // Учётные данные поменялись — открытая сессия держит
                        // старый пароль, поэтому следующая операция должна
                        // подключиться заново.
                        session.credentialsDidChange(updated.id)
                    }
                    // Не перебивать выбор пользователя, если за время
                    // системного запроса связки ключей он уже переключился
                    // на другой роутер.
                    if session.activeRouterID == activeBeforeSave {
                        await session.switchTo(updated)
                    }
                    refreshPasswordFlags()
                }
            } onCancel: { editing = nil }
        }
        .confirmationDialog("Удалить роутер?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let victim = confirmDelete {
                    let wasActive = victim.id == session.router.id
                    store.remove(victim)
                    session.forget(victim.id)
                    // Иначе окно осталось бы на роутере, которого уже нет
                    // в списке: карточка в панели показывала призрак.
                    if wasActive, let next = store.selectedRouter {
                        Task { await session.switchTo(next) }
                    }
                    refreshPasswordFlags()
                }
                confirmDelete = nil
            }
            Button("Отмена", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("Пароль роутера тоже будет удалён из связки ключей.")
        }
    }

    // MARK: - Роутеры

    private var routers: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    routersHeader
                    Spacer()
                    addRouterButton
                }
                .frame(minWidth: 560)

                VStack(alignment: .leading, spacing: 8) {
                    routersHeader
                    addRouterButton
                }
            }

            VStack(spacing: 0) {
                ForEach(store.routers) { router in
                    routerRow(router)
                    if router.id != store.routers.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .inset()
        }
        .card()
        .onAppear(perform: refreshPasswordFlags)
        .onChange(of: store.routers) { _, _ in refreshPasswordFlags() }
    }

    private var routersHeader: some View {
        CardHeader(icon: "wifi.router", title: "Роутеры",
                   subtitle: "Пароли лежат в связке ключей macOS, а не в файлах приложения")
    }

    private var addRouterButton: some View {
        Button("Добавить роутер") { editing = RouterProfile() }
            .buttonStyle(PrimaryButtonStyle())
    }

    private func refreshPasswordFlags() {
        let known = store.routers
        Task {
            let ids = await Task.detached {
                Set(known.filter { $0.password?.isEmpty == false }.map(\.id))
            }.value
            havePassword = ids
        }
    }

    private func routerRow(_ router: RouterProfile) -> some View {
        let isCurrent = router.id == session.router.id
        let fromEnvironment = router.environmentPassword != nil
        let known = havePassword
        let hasPassword = fromEnvironment || (known?.contains(router.id) ?? false)

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 11) {
                routerIcon(isCurrent: isCurrent)
                routerIdentity(router, isCurrent: isCurrent)
                Spacer(minLength: 8)
                routerBadges(router, fromEnvironment: fromEnvironment,
                             known: known, hasPassword: hasPassword)
                routerActions(router)
            }
            .frame(minWidth: 660)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    routerIcon(isCurrent: isCurrent)
                    routerIdentity(router, isCurrent: isCurrent)
                    Spacer(minLength: 4)
                    routerActions(router)
                }
                HStack(spacing: 7) {
                    routerBadges(router, fromEnvironment: fromEnvironment,
                                 known: known, hasPassword: hasPassword)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedRouterID = router.id
            Task { await session.switchTo(router) }
        }
    }

    private func routerIcon(isCurrent: Bool) -> some View {
        Image(systemName: isCurrent ? "wifi.router.fill" : "wifi.router")
            .font(.system(size: 15))
            .foregroundStyle(isCurrent ? Palette.accent : .secondary)
            .frame(width: 22)
    }

    private func routerIdentity(_ router: RouterProfile, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Text(router.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if isCurrent { StatusPill(text: "активный", tint: Palette.accent) }
            }
            Text(router.subtitle)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func routerBadges(_ router: RouterProfile, fromEnvironment: Bool,
                              known: Set<UUID>?, hasPassword: Bool) -> some View {
        Group {
            StatusPill(text: router.transport.shortTitle, tint: .secondary, icon: router.transport.icon)
            if fromEnvironment {
                StatusPill(text: "пароль из окружения", tint: Palette.success)
            } else if known == nil {
                StatusPill(text: "проверяю…", tint: .secondary)
                    .help("Читаю пароль из связки ключей macOS")
            } else {
                StatusPill(text: hasPassword ? "пароль сохранён" : "нет пароля",
                           tint: hasPassword ? Palette.success : Palette.warning)
            }
        }
    }

    private func routerActions(_ router: RouterProfile) -> some View {
        HStack(spacing: 8) {
            Button("Изменить") { editing = router }
                .buttonStyle(SubtleButtonStyle())

            Button {
                confirmDelete = router
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.danger)
            .disabled(store.routers.count <= 1)
        }
    }

    // MARK: - Настройки

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: "slider.horizontal.3", title: "Параметры работы",
                       subtitle: "Значения по умолчанию совпадают с консольным скриптом")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 14) {
                numberField("Доменов в одной части списка", value: $store.settings.chunkSize,
                            range: 10...1000,
                            hint: "Прошивка не любит очень длинные object-group.")
                numberField("Потолок для проверки", value: $store.settings.maxDomainsPerList,
                            range: 10...2000,
                            hint: "После применения списки сверяются с этим числом.")
                numberField("Команд в одной пачке", value: $store.settings.batchSize,
                            range: 1...64,
                            hint: "Больше — быстрее, но дольше ловится ошибочная команда.")
                numberField("Кэш источников, мин", value: $store.settings.cacheTTLMinutes,
                            range: 0...1440,
                            hint: "0 — качать заново каждый раз.")
                numberField("Хранить резервных копий", value: $store.settings.keepBackups,
                            range: 1...200,
                            hint: "Старые снимки удаляются автоматически.")
                numberField("Проверка VPN, с", value: $store.settings.wireGuardProbeIntervalSeconds,
                            range: 3...300,
                            hint: "Как часто обновлять пинг всех WireGuard-туннелей.")
            }

            Divider()

            Toggle(isOn: $store.settings.defaultAuto) {
                Text("По умолчанию ставить флаг auto у маршрутов")
                    .font(.system(size: 12))
            }
            Toggle(isOn: $store.settings.defaultReject) {
                Text("По умолчанию ставить флаг reject")
                    .font(.system(size: 12))
            }
            Toggle(isOn: $store.settings.removeStaleByDefault) {
                Text("По умолчанию убирать домены, пропавшие из источника")
                    .font(.system(size: 12))
            }
            Toggle(isOn: $store.settings.saveConfigAfterApply) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Сохранять конфигурацию роутера после применения")
                        .font(.system(size: 12))
                    Text("Без этого изменения пропадут после перезагрузки роутера.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    private func numberField(_ title: String, value: Binding<Int>,
                             range: ClosedRange<Int>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("", value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }),
                          format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .help("От \(range.lowerBound) до \(range.upperBound)")
                Stepper("", value: value, in: range)
                    .labelsHidden()
                Spacer()
            }
            Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Фоновая сверка

    private var autoUpdate: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    autoUpdateHeader
                    Spacer()
                    checkNowButton
                }
                .frame(minWidth: 560)

                VStack(alignment: .leading, spacing: 8) {
                    autoUpdateHeader
                    checkNowButton
                }
            }

            Toggle(isOn: Binding(get: { store.settings.autoUpdateEnabled },
                                 set: { store.settings.autoUpdateEnabled = $0; updater.reschedule() })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Проверять в фоне").font(.system(size: 12, weight: .medium))
                    Text("Сверка только читает источники и сравнивает их с последней "
                         + "прочитанной конфигурацией. На роутер она НИЧЕГО не отправляет "
                         + "и сама к нему не подключается — применять план решаешь ты.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 20)],
                      alignment: .leading, spacing: 14) {
                numberField("Раз в сколько часов", value: Binding(
                    get: { store.settings.autoUpdateHours },
                    set: { store.settings.autoUpdateHours = $0; updater.reschedule() }),
                            range: 1...168,
                            hint: "Проверка запускается и при открытии приложения.")

                VStack(alignment: .leading, spacing: 4) {
                    Text("Состояние").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(updater.lastMessage ?? "ещё не проверялось")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    if let last = updater.lastCheck {
                        Text("последняя проверка \(Format.age(last))")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }

            Toggle(isOn: $store.settings.autoUpdateNotify) {
                Text("Показывать системное уведомление при расхождении")
                    .font(.system(size: 12))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Какие источники сверять").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(store.settings.autoUpdateSources.isEmpty
                     ? "Ничего не отмечено — сверяются все."
                     : "Отмечено: \(store.settings.autoUpdateSources.count)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)],
                          alignment: .leading, spacing: 6) {
                    ForEach(store.allSources) { spec in
                        let picked = store.settings.autoUpdateSources.contains(spec.key)
                        Toggle(isOn: Binding(
                            get: { picked },
                            set: { on in
                                var chosen = store.settings.autoUpdateSources
                                if on { chosen.append(spec.key) } else { chosen.removeAll { $0 == spec.key } }
                                store.settings.autoUpdateSources = chosen
                            })) {
                            Text(spec.title).font(.system(size: 11)).lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .card()
    }

    private var autoUpdateHeader: some View {
        CardHeader(icon: "arrow.triangle.2.circlepath", title: "Сверка источников",
                   subtitle: "Приложение само проверяет, не разошлись ли списки")
    }

    private var checkNowButton: some View {
        Button {
            Task { await updater.check(manual: true) }
        } label: {
            HStack(spacing: 6) {
                if updater.checking { ProgressView().controlSize(.small) }
                Text(updater.checking ? "Проверяю…" : "Проверить сейчас")
            }
        }
        .buttonStyle(SubtleButtonStyle())
        .disabled(updater.checking)
    }

    // MARK: - Данные на диске

    private var storage: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "internaldrive", title: "Где что лежит",
                       subtitle: "Всё хозяйство приложения — в одной папке")

            VStack(alignment: .leading, spacing: 7) {
                KeyValueRow(key: "Данные приложения", value: AppPaths.support.path, monospaced: true)
                KeyValueRow(key: "Резервные копии", value: AppPaths.backups.path, monospaced: true)
                KeyValueRow(key: "Кэш источников", value: AppPaths.cache.path, monospaced: true)
                KeyValueRow(key: "Журнал", value: AppPaths.logs.path, monospaced: true)
            }
            .padding(12)
            .inset()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    openDataButton
                    clearCacheButton
                }
                .frame(minWidth: 390)

                VStack(alignment: .leading, spacing: 8) {
                    openDataButton
                    clearCacheButton
                }
            }
        }
        .card()
    }

    private var openDataButton: some View {
        Button("Открыть папку данных") { NSWorkspace.shared.open(AppPaths.support) }
            .buttonStyle(SubtleButtonStyle())
    }

    private var clearCacheButton: some View {
        Button("Очистить кэш источников") {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: AppPaths.cache, includingPropertiesForKeys: nil)) ?? []
            for file in files { try? FileManager.default.removeItem(at: file) }
            log(.ok, "Кэш источников очищен (\(files.count) файлов).")
        }
        .buttonStyle(SubtleButtonStyle())
    }
}

// MARK: - Карточка роутера

struct RouterEditor: View {
    @State var profile: RouterProfile
    var onSave: (RouterProfile, String?) -> Void
    var onCancel: () -> Void

    @State private var password = ""
    @State private var passwordLoaded = false
    /// Нельзя отличить «поле ещё не успело прочитаться» от «человек очистил
    /// пароль» по одной пустой строке. Этот флаг позволяет и сохранить
    /// существующий пароль без лишнего запроса, и честно удалить его.
    @State private var passwordTouched = false
    @State private var showPassword = false

    private var passwordBinding: Binding<String> {
        Binding(get: { password }, set: {
            password = $0
            passwordTouched = true
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(icon: "wifi.router", title: profile.name.isEmpty ? "Новый роутер" : profile.name,
                       subtitle: "Пароль хранится в связке ключей macOS")

            field("Название") {
                TextField("Дом", text: $profile.name).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Как подключаться")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Picker("", selection: $profile.transport) {
                    ForEach(TransportKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(profile.transport == .ssh
                     ? "Приложение поднимает настоящий терминал через /usr/bin/ssh — так же, как консольный скрипт."
                     : "Работает через веб-панель роутера: помогает там, где SSH закрыт, и отдаёт структурированные данные.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if profile.transport == .ssh {
                HStack(spacing: 12) {
                    field("Адрес роутера") {
                        TextField("192.168.1.1", text: $profile.host)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    field("Порт", width: 90) {
                        TextField("22", value: $profile.port, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } else {
                field("Адрес веб-панели") {
                    TextField("http://192.168.1.1/", text: $profile.webURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                Text("Только корневой адрес — без /auth, /rci и прочих путей. "
                     + "Пусто — возьмём http://\(profile.host)/")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                field("Пользователь") {
                    TextField("admin", text: $profile.user).textFieldStyle(.roundedBorder)
                }
                field("Пароль") {
                    HStack(spacing: 6) {
                        Group {
                            if showPassword {
                                TextField("", text: passwordBinding)
                            } else {
                                SecureField("", text: passwordBinding)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Отмена", action: onCancel)
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Сохранить") {
                    var cleaned = profile
                    cleaned.name = cleaned.name.trimmingCharacters(in: .whitespaces)
                    cleaned.host = cleaned.host.trimmingCharacters(in: .whitespaces)
                    cleaned.user = cleaned.user.trimmingCharacters(in: .whitespaces)
                    if cleaned.name.isEmpty { cleaned.name = cleaned.host }
                    // nil — пароль не меняли; пустая строка — удалить его из
                    // связки ключей. Раньше очистить поле и сохранить было
                    // невозможно: старый пароль оставался незаметно.
                    onSave(cleaned, passwordTouched ? password : nil)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(profile.host.trimmingCharacters(in: .whitespaces).isEmpty
                          && profile.webURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(minWidth: 440, idealWidth: 560, maxWidth: 560)
        .background(Palette.surface)
        .task {
            guard !passwordLoaded else { return }
            let account = profile.keychainAccount
            // SecItemCopyMatching умеет показать системный запрос доступа и
            // ждать ответа сколько угодно — на главном потоке окно бы замерло.
            let stored = await Task.detached { Keychain.load(account: account) }.value
            if !passwordTouched { password = stored ?? "" }
            passwordLoaded = true
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
