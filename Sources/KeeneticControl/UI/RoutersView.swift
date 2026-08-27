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
    @State private var havePassword: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                routers
                settings
                storage
            }
            .padding(20)
        }
        .sheet(item: $editing) { profile in
            RouterEditor(profile: profile) { updated, password in
                editing = nil
                if store.routers.contains(where: { $0.id == updated.id }) {
                    store.update(updated)
                } else {
                    store.add(updated)
                }
                if let password { updated.password = password }
                Task { await session.switchTo(updated) }
            } onCancel: { editing = nil }
        }
        .confirmationDialog("Удалить роутер?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let victim = confirmDelete { store.remove(victim) }
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
            HStack {
                CardHeader(icon: "wifi.router", title: "Роутеры",
                           subtitle: "Пароли лежат в связке ключей macOS, а не в файлах приложения")
                Spacer()
                Button("Добавить роутер") { editing = RouterProfile() }
                    .buttonStyle(PrimaryButtonStyle())
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
        let hasPassword = fromEnvironment || havePassword.contains(router.id)

        return HStack(spacing: 11) {
            Image(systemName: isCurrent ? "wifi.router.fill" : "wifi.router")
                .font(.system(size: 15))
                .foregroundStyle(isCurrent ? Palette.accent : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(router.name).font(.system(size: 13, weight: .semibold))
                    if isCurrent { StatusPill(text: "активный", tint: Palette.accent) }
                }
                Text(router.subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            StatusPill(text: router.transport.shortTitle, tint: .secondary, icon: router.transport.icon)
            StatusPill(text: fromEnvironment ? "пароль из окружения"
                             : (hasPassword ? "пароль сохранён" : "нет пароля"),
                       tint: hasPassword ? Palette.success : Palette.warning)

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
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedRouterID = router.id
            Task { await session.switchTo(router) }
        }
    }

    // MARK: - Настройки

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: "slider.horizontal.3", title: "Параметры работы",
                       subtitle: "Значения по умолчанию совпадают с консольным скриптом")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 2), spacing: 14) {
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
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Stepper("", value: value, in: range)
                    .labelsHidden()
                Spacer()
            }
            Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
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

            HStack(spacing: 8) {
                Button("Открыть папку данных") { NSWorkspace.shared.open(AppPaths.support) }
                    .buttonStyle(SubtleButtonStyle())
                Button("Очистить кэш источников") {
                    let files = (try? FileManager.default.contentsOfDirectory(
                        at: AppPaths.cache, includingPropertiesForKeys: nil)) ?? []
                    for file in files { try? FileManager.default.removeItem(at: file) }
                    log(.ok, "Кэш источников очищен (\(files.count) файлов).")
                }
                .buttonStyle(SubtleButtonStyle())
            }
        }
        .card()
    }
}

// MARK: - Карточка роутера

struct RouterEditor: View {
    @State var profile: RouterProfile
    var onSave: (RouterProfile, String?) -> Void
    var onCancel: () -> Void

    @State private var password = ""
    @State private var passwordLoaded = false
    @State private var showPassword = false

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
                                TextField("", text: $password)
                            } else {
                                SecureField("", text: $password)
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
                    onSave(cleaned, password.isEmpty ? nil : password)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(profile.host.trimmingCharacters(in: .whitespaces).isEmpty
                          && profile.webURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Palette.surface)
        .onAppear {
            guard !passwordLoaded else { return }
            password = profile.password ?? ""
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
