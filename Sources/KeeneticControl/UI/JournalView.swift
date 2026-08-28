import AppKit
import SwiftUI

struct JournalView: View {
    @ObservedObject private var store = LogStore.shared
    @State private var filter: LogLevel?
    @State private var query = ""
    /// Пока журнал сам прыгал в конец, прочитать что-то выше было нельзя:
    /// любая новая строка утаскивала список обратно.
    @State private var followTail = true

    private var entries: [LogEntry] {
        store.entries.filter { entry in
            (filter == nil || entry.level == filter)
                && (query.isEmpty || entry.text.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                CardHeader(icon: "text.alignleft", title: "Журнал работы",
                           subtitle: "Полная копия пишется в \(AppPaths.logs.lastPathComponent)/keenetic-control.log")
                Spacer()

                TextField("Поиск", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)

                Picker("", selection: $filter) {
                    Text("Всё").tag(LogLevel?.none)
                    Text("Ошибки").tag(LogLevel?.some(.error))
                    Text("Предупреждения").tag(LogLevel?.some(.warn))
                    Text("Команды").tag(LogLevel?.some(.cmd))
                    Text("Успешно").tag(LogLevel?.some(.ok))
                    Text("Сообщения").tag(LogLevel?.some(.info))
                }
                .pickerStyle(.menu)
                .frame(width: 150)

                Toggle("За хвостом", isOn: $followTail)
                    .toggleStyle(.checkbox)
                    .help("Прокручивать журнал к новым строкам")

                Button("Копировать") {
                    // Копируем то, что отфильтровано и видно, а не весь журнал:
                    // иначе кнопка рядом с фильтром обманывает.
                    let text = entries
                        .map { "\($0.stamp) [\($0.level.rawValue)] \($0.text)" }
                        .joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text.isEmpty ? store.plainText : text,
                                                   forType: .string)
                }
                .buttonStyle(SubtleButtonStyle())

                Button("Очистить") { store.clear() }
                    .buttonStyle(SubtleButtonStyle())
                    .disabled(store.entries.isEmpty)
            }

            if entries.isEmpty {
                EmptyHint(icon: "text.alignleft",
                          title: store.entries.isEmpty ? "Журнал пуст" : "Ничего не нашлось",
                          message: store.entries.isEmpty
                            ? "Здесь появится всё, что приложение делает с роутером."
                            : "Поменяй фильтр или поисковый запрос.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .inset()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(entries) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(entry.stamp)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    Image(systemName: entry.level.symbol)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(entry.level.tint)
                                        .frame(width: 12)
                                    Text(entry.text)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(entry.level == .error ? Palette.danger : .primary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 1)
                                .id(entry.id)
                            }
                        }
                        .padding(12)
                    }
                    .inset()
                    .onChange(of: entries.count) { _, _ in
                        guard followTail, let last = entries.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                    .onChange(of: followTail) { _, isOn in
                        guard isOn, let last = entries.last else { return }
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(20)
    }
}
