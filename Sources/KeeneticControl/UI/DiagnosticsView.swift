import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var session: RouterSession
    @Binding var alert: AlertPayload?

    @State private var interfaceIdent = ""
    @State private var target = ""
    @State private var report: RouterDiagnosticsReport?
    @State private var running = false
    @State private var lastError: String?

    private var interfaces: [String] {
        session.state?.wireguardInterfaces ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let progress = session.progress { ProgressBanner(info: progress) }

                if session.state == nil {
                    EmptyHint(icon: "bolt.horizontal.circle",
                              title: "Роутер не прочитан",
                              message: "Подключись к роутеру и нажми «Обновить», чтобы запустить диагностику.")
                        .card(padding: 24)
                } else if interfaces.isEmpty {
                    EmptyHint(icon: "stethoscope",
                              title: "WireGuard-интерфейсов нет",
                              message: "Диагностика доступна для интерфейсов WireGuard, которые есть в конфигурации.")
                        .card(padding: 24)
                } else {
                    controls
                    if let report {
                        reportCard(report)
                    } else {
                        EmptyHint(icon: "waveform.path.ecg",
                                  title: "Проверка ещё не запускалась",
                                  message: "Ничего не меняется: приложение только читает состояние роутера и конфигурацию.")
                            .card(padding: 24)
                    }
                }
            }
            .padding(20)
        }
        .onAppear { syncDefaults(force: true) }
        .onChange(of: session.state?.readAt) { _, _ in
            if !interfaces.contains(interfaceIdent) { syncDefaults(force: true) }
            else if target.isEmpty { syncTarget() }
        }
        .onChange(of: interfaceIdent) { _, _ in
            report = nil
            lastError = nil
            syncTarget()
        }
        .onChange(of: session.router.id) { _, _ in
            report = nil
            lastError = nil
            syncDefaults(force: true)
        }
        .alert(item: Binding(get: {
            lastError.map { AlertPayload(title: "Диагностика не завершилась", message: $0) }
        }, set: { _ in lastError = nil })) { payload in
            Alert(title: Text(payload.title), message: Text(payload.message),
                  dismissButton: .default(Text("Понятно")))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "stethoscope", title: "Диагностика соединения",
                       subtitle: "DNS · маршрут · MTU")

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 10) {
                    interfacePicker
                    targetField
                    runButton
                }
                VStack(alignment: .leading, spacing: 9) {
                    interfacePicker
                    targetField
                    runButton
                }
            }

            Text("Проверка читает состояние роутера и текущую конфигурацию; настройки не изменяются.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .card()
    }

    private var interfacePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Интерфейс")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("Интерфейс", selection: $interfaceIdent) {
                ForEach(interfaces, id: \.self) { ident in
                    Text(session.state?.label(for: ident) ?? ident).tag(ident)
                }
            }
            .frame(minWidth: 190, idealWidth: 250, maxWidth: 320)
        }
    }

    private var targetField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Цель Ping-Check")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("например, 1.1.1.1 или google.com", text: $target)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, idealWidth: 250, maxWidth: 320)
        }
    }

    private var runButton: some View {
        Button {
            Task { await run() }
        } label: {
            Label(running ? "Проверяю…" : "Проверить сейчас",
                  systemImage: running ? "hourglass" : "stethoscope")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(running || interfaceIdent.isEmpty || session.state == nil || session.progress != nil)
    }

    private func reportCard(_ report: RouterDiagnosticsReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    CardHeader(icon: "checkmark.shield", title: "Результат проверки",
                               subtitle: "\(session.state?.label(for: report.interface) ?? report.interface) · \(report.target.isEmpty ? "цель не указана" : report.target)")
                    Spacer(minLength: 8)
                    Text(report.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    CardHeader(icon: "checkmark.shield", title: "Результат проверки",
                               subtitle: "\(session.state?.label(for: report.interface) ?? report.interface) · \(report.target.isEmpty ? "цель не указана" : report.target)")
                    Text(report.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    ForEach(report.checks) { check in
                        DiagnosticCheckCard(check: check)
                    }
                }
                VStack(spacing: 10) {
                    ForEach(report.checks) { check in
                        DiagnosticCheckCard(check: check)
                    }
                }
            }

            Button("Проверить ещё раз") { Task { await run() } }
                .buttonStyle(SubtleButtonStyle())
                .disabled(running)

            if let lastError {
                Text(lastError)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private func syncDefaults(force: Bool) {
        guard let first = interfaces.first else {
            interfaceIdent = ""
            target = ""
            report = nil
            return
        }
        if force || !interfaces.contains(interfaceIdent) { interfaceIdent = first }
        syncTarget()
        if force { report = nil }
    }

    private func syncTarget() {
        guard let profileName = session.state?.pingCheckBindings[interfaceIdent]?.profile,
              let profile = session.state?.pingCheckProfiles.first(where: { $0.name == profileName })
        else {
            if report?.interface != interfaceIdent { target = "" }
            return
        }
        if target.isEmpty || report?.interface != interfaceIdent { target = profile.target }
    }

    private func run() async {
        let selectedInterface = interfaceIdent
        guard !selectedInterface.isEmpty, session.state != nil else { return }
        running = true
        lastError = nil
        defer { running = false }

        if session.status.isOnline {
            do {
                _ = try await session.refreshLiveInterface(selectedInterface)
            } catch is CancellationError {
                return
            } catch {
                // Диагностика всё равно полезна по последнему снимку; ошибку
                // показываем под результатом, не пряча уже собранные данные.
                lastError = session.describe(error)
            }
        } else {
            lastError = "Роутер не подключён — показан последний прочитанный снимок."
        }

        guard !Task.isCancelled, selectedInterface == interfaceIdent,
              let state = session.state else { return }
        report = RouterDiagnosticsBuilder.build(state: state,
                                                interface: selectedInterface,
                                                target: target)
    }
}

struct DiagnosticCheckCard: View {
    let check: DiagnosticCheck

    private var tint: Color {
        switch check.severity {
        case .pass:    return Palette.success
        case .warning: return Palette.warning
        case .failure: return Palette.danger
        case .info:    return Palette.accent
        }
    }

    private var icon: String {
        switch check.severity {
        case .pass:    return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .info:    return "info.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(check.title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(check.severity.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint)
            }
            Text(check.value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(check.detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .inset(cornerRadius: 10)
    }
}
