import SwiftUI

struct PortableBackupRequest: Identifiable {
    enum Mode { case importFile(URL), exportFile(URL, URL) }
    let id = UUID()
    var mode: Mode
    var host: String
    var isExport: Bool { if case .exportFile = mode { return true }; return false }
}

struct PortableBackupSheet: View {
    let request: PortableBackupRequest
    var onComplete: (URL?) -> Void
    var onCancel: () -> Void
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(icon: "lock.shield", title: request.isExport ? "Экспорт с паролем" : "Импорт копии",
                       subtitle: "Переносимая зашифрованная копия")
            Text(request.isExport
                 ? "Эту копию можно открыть на другом Mac. Сохрани пароль отдельно: восстановить его нельзя."
                 : "Укажи пароль, заданный при экспорте. Копия появится в приложении; изменения на роутере выполняются отдельно, после сверки.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(request.isExport ? "Пароль — от 12 символов" : "Пароль копии", text: $password)
                .textFieldStyle(.roundedBorder)
                .disabled(busy)
            if request.isExport {
                SecureField("Повтори пароль", text: $confirmation)
                    .textFieldStyle(.roundedBorder).disabled(busy)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Отмена") { clear(); onCancel() }
                    .buttonStyle(SubtleButtonStyle()).keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(busy ? "Обрабатываю…" : request.isExport ? "Зашифровать и сохранить" : "Открыть копию") {
                    Task { await perform() }
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(busy || password.isEmpty || (request.isExport && (password.count < 12 || password != confirmation)))
            }
        }
        .padding(22).frame(width: 470)
        .background(Palette.surface)
        .interactiveDismissDisabled(busy)
        .onDisappear(perform: clear)
    }

    private func clear() { password = ""; confirmation = "" }

    @MainActor private func perform() async {
        guard !busy else { return }
        busy = true; error = nil
        let secret = password
        clear()
        defer { busy = false }
        do {
            let imported: URL? = try await Task.detached(priority: .userInitiated) {
                switch request.mode {
                case .importFile(let source):
                    return try Backups.importPortable(source, password: secret, host: request.host)
                case .exportFile(let source, let target):
                    try PortableBackup.write(Backups.read(source), to: target, password: secret)
                    return nil
                }
            }.value
            onComplete(imported)
        } catch { self.error = error.localizedDescription }
    }
}
