import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WireGuardView: View {
    @EnvironmentObject private var session: RouterSession
    @Binding var alert: AlertPayload?

    @State private var interfaceIdent = ""
    @State private var config: WireGuardConfig?
    @State private var parseError: String?
    @State private var dropTargeted = false
    @State private var hasBaseline = false
    @State private var confirmUpdate = false
    @State private var confirmRollback = false
    @State private var working = false
    @State private var result: WireGuardUpdateResult?

    private var interfaces: [String] { session.state?.wireguardInterfaces ?? [] }

    private var liveState: WireGuardState? {
        guard let text = session.state?.configText, !interfaceIdent.isEmpty else { return nil }
        return WireGuardState.parse(config: text, interface: interfaceIdent)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let progress = session.progress { ProgressBanner(info: progress) }

                if session.state == nil {
                    notConnected
                } else if interfaces.isEmpty {
                    noInterfaces
                } else {
                    interfaceCard
                    HStack(alignment: .top, spacing: 16) {
                        fileCard
                        actionsCard
                    }
                }
            }
            .padding(20)
        }
        .onAppear(perform: pickDefault)
        .onChange(of: session.state?.readAt) { _, _ in pickDefault() }
        .onChange(of: interfaceIdent) { _, _ in refreshBaseline() }
        .confirmationDialog("Обновить \(interfaceIdent) новым конфигом?",
                            isPresented: $confirmUpdate, titleVisibility: .visible) {
            Button("Безопасно обновить") { Task { await update() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Перед изменением снимется резервная копия конфигурации. "
                 + "Если что-то пойдёт не так, приложение само вернёт rollback-базу.")
        }
        .confirmationDialog("Откатить \(interfaceIdent) на rollback-базу?",
                            isPresented: $confirmRollback, titleVisibility: .visible) {
            Button("Откатить", role: .destructive) { Task { await rollback() } }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(item: Binding(get: { result.map(WGResultBox.init) }, set: { result = $0?.value })) { box in
            WireGuardResultSheet(result: box.value) { result = nil }
        }
    }

    // MARK: - Пустые состояния

    private var notConnected: some View {
        EmptyHint(icon: "bolt.horizontal.circle", title: "Роутер не прочитан",
                  message: "Подключись и нажми «Обновить» — здесь появятся WireGuard-интерфейсы.")
            .card(padding: 24)
    }

    private var noInterfaces: some View {
        EmptyHint(icon: "shield.slash", title: "WireGuard-интерфейсов нет",
                  message: "Создай интерфейс Wireguard в веб-панели Keenetic — "
                         + "приложение обновляет существующие, но не создаёт новые.")
            .card(padding: 24)
    }

    // MARK: - Состояние интерфейса

    private var interfaceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CardHeader(icon: "shield.lefthalf.filled", title: "WireGuard / AmneziaWG",
                           subtitle: "Безопасное обновление с бэкапом и автоматическим откатом")
                Spacer()
                Picker("", selection: $interfaceIdent) {
                    ForEach(interfaces, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
            }

            if let live = liveState {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    MetricTile(value: live.isUp ? "включён" : "выключен",
                               label: "Состояние", icon: "power",
                               tint: live.isUp ? Palette.success : Palette.warning)
                    MetricTile(value: String(live.peerKeys.count), label: "Пиров",
                               icon: "person.2", tint: live.peerKeys.count == 1 ? Palette.success : Palette.warning)
                    MetricTile(value: live.listenPort.isEmpty ? "—" : live.listenPort,
                               label: "ListenPort", icon: "number")
                    MetricTile(value: String(WireGuardService.routeCount(session.state?.configText ?? "")),
                               label: "Маршрутов у роутера", icon: "arrow.triangle.branch")
                }

                VStack(alignment: .leading, spacing: 7) {
                    if !live.descriptionText.isEmpty {
                        KeyValueRow(key: "Описание", value: live.descriptionText)
                    }
                    if !live.addresses.isEmpty {
                        KeyValueRow(key: "Адрес интерфейса",
                                    value: live.addresses.joined(separator: ", "), monospaced: true)
                    }
                    ForEach(live.peerKeys, id: \.self) { key in
                        KeyValueRow(key: "PublicKey пира", value: key, monospaced: true)
                    }
                }
                .padding(12)
                .inset()
            }

            HStack(spacing: 8) {
                if hasBaseline {
                    StatusPill(text: "Rollback-база готова", tint: Palette.success, icon: "checkmark")
                } else {
                    StatusPill(text: "Rollback-база НЕ задана", tint: Palette.danger, icon: "exclamationmark")
                }
                Text(hasBaseline
                     ? "Есть куда откатиться, если обновление не приживётся."
                     : "Загрузи ТЕКУЩИЙ рабочий .conf и нажми «Сделать rollback-базой» — без этого обновление заблокировано.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    // MARK: - Файл конфигурации

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "doc.badge.arrow.up", title: "Конфигурация .conf",
                       subtitle: "Перетащи файл сюда или выбери вручную")

            VStack(spacing: 10) {
                Image(systemName: dropTargeted ? "arrow.down.doc.fill" : "doc.text")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(dropTargeted ? Palette.accent : Color.secondary.opacity(0.45))

                if let config {
                    Text(config.fileName.isEmpty ? "Конфигурация загружена" : config.fileName)
                        .font(.system(size: 12, weight: .semibold))
                    StatusPill(text: config.flavour, tint: Palette.accent)
                } else {
                    Text("Файл не выбран")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Поддерживаются WireGuard, AmneziaWG и AmneziaWG 2.0")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Button("Выбрать .conf…") { pickFile() }
                    .buttonStyle(SubtleButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(dropTargeted ? Palette.accent.opacity(0.08) : Palette.inset))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(dropTargeted ? Palette.accent : Palette.stroke,
                              style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                loadDropped(providers)
            }

            if let parseError {
                Text(parseError)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let config {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(config.summaryRows.enumerated()), id: \.offset) { _, row in
                        KeyValueRow(key: row.0, value: row.1,
                                    monospaced: row.0.contains("Key") || row.0.contains("Allowed")
                                             || row.0.contains("Endpoint") || row.0.contains("Адрес"))
                    }
                }
                .padding(12)
                .inset()
            }
        }
        .card()
    }

    // MARK: - Действия

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "bolt.shield", title: "Операции", subtitle: "Порядок действий имеет значение")

            step(number: 1,
                 title: "Сделать rollback-базой",
                 text: "Один раз загрузи ТЕКУЩИЙ рабочий .conf интерфейса и нажми эту кнопку. "
                     + "Приложение запомнит его в связке ключей — это точка возврата.",
                 button: "Сделать rollback-базой",
                 tint: Palette.accent,
                 enabled: config != nil && !working) {
                guard let config else { return }
                WireGuardVault.saveBaseline(config.sourceText, router: session.router, interface: interfaceIdent)
                refreshBaseline()
                log(.ok, "Rollback-база для \(interfaceIdent) сохранена.")
            }

            Divider()

            step(number: 2,
                 title: "Безопасно обновить",
                 text: "Бэкап → новый пир без AllowedIPs → адреса и ключи → проверка → "
                     + "удаление старого пира → включение → сохранение. При осечке — автоматический откат.",
                 button: "Безопасно обновить",
                 tint: Palette.success,
                 enabled: config != nil && hasBaseline && !working && session.progress == nil) {
                confirmUpdate = true
            }

            Divider()

            step(number: 3,
                 title: "Откатить обновление",
                 text: "Возвращает интерфейс на сохранённую rollback-базу. Файл .conf для этого не нужен.",
                 button: "Откатить обновление",
                 tint: Palette.warning,
                 enabled: hasBaseline && !working && session.progress == nil) {
                confirmRollback = true
            }

            if hasBaseline {
                Divider()
                Button("Забыть rollback-базу") {
                    WireGuardVault.clearBaseline(router: session.router, interface: interfaceIdent)
                    refreshBaseline()
                }
                .buttonStyle(SubtleButtonStyle(tint: Palette.danger))
            }
        }
        .card()
    }

    private func step(number: Int, title: String, text: String, button: String,
                      tint: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(tint.opacity(0.15)).frame(width: 20, height: 20)
                    Text(String(number))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action)
                .buttonStyle(PrimaryButtonStyle(tint: tint))
                .disabled(!enabled)
        }
    }

    // MARK: - Логика

    private func pickDefault() {
        if interfaceIdent.isEmpty || !interfaces.contains(interfaceIdent) {
            interfaceIdent = interfaces.first ?? ""
        }
        refreshBaseline()
    }

    private func refreshBaseline() {
        guard !interfaceIdent.isEmpty else { hasBaseline = false; return }
        hasBaseline = WireGuardVault.hasBaseline(router: session.router, interface: interfaceIdent)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .data]
        panel.message = "Выбери файл конфигурации WireGuard (.conf)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func loadDropped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { load(url) }
        }
        return true
    }

    private func load(_ url: URL) {
        parseError = nil
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            config = try WireGuardConfig.parse(text: text, fileName: url.lastPathComponent)
            log(.info, "Загружен конфиг \(url.lastPathComponent) (\(config?.flavour ?? "")).")
        } catch {
            config = nil
            parseError = (error as? TransportError)?.message ?? error.localizedDescription
        }
    }

    private func update() async {
        guard let config else { return }
        working = true
        defer { working = false }
        do {
            result = try await WireGuardService.safeUpdate(
                session: session, interface: interfaceIdent, config: config)
            refreshBaseline()
        } catch {
            alert = AlertPayload(title: "Обновление не удалось", message: session.describe(error))
        }
    }

    private func rollback() async {
        working = true
        defer { working = false }
        do {
            try await WireGuardService.rollback(session: session, interface: interfaceIdent)
            alert = AlertPayload(title: "Откат выполнен",
                                 message: "Интерфейс \(interfaceIdent) вернулся на rollback-базу.",
                                 isError: false)
        } catch {
            alert = AlertPayload(title: "Откат не удался", message: session.describe(error))
        }
    }
}

struct WGResultBox: Identifiable {
    let id = UUID()
    let value: WireGuardUpdateResult
    init(_ value: WireGuardUpdateResult) { self.value = value }
}

struct WireGuardResultSheet: View {
    let result: WireGuardUpdateResult
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: result.warnings.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(result.warnings.isEmpty ? Palette.success : Palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.rolledBack ? "Откачено" : "Интерфейс обновлён")
                        .font(.system(size: 16, weight: .semibold))
                    Text(result.interface).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 7) {
                KeyValueRow(key: "Маршрутов до", value: String(result.routesBefore))
                KeyValueRow(key: "Маршрутов после", value: String(result.routesAfter))
                if let backup = result.backupURL {
                    KeyValueRow(key: "Резервная копия", value: backup.lastPathComponent, monospaced: true)
                }
            }
            .padding(12)
            .inset()

            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Замечания").font(.system(size: 12, weight: .semibold))
                    ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                        Text("• " + warning)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .inset()
            }

            HStack {
                if let backup = result.backupURL {
                    Button("Показать бэкап") {
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
        .frame(width: 560)
        .background(Palette.surface)
    }
}
