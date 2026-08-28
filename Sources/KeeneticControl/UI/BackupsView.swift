import AppKit
import SwiftUI

struct BackupsView: View {
    @EnvironmentObject private var session: RouterSession
    @Binding var alert: AlertPayload?

    /// Размер и дату файла собираем один раз при обновлении списка.
    /// Раньше это читалось с диска прямо в body — на каждую перерисовку.
    private struct Snapshot: Identifiable, Hashable {
        let url: URL
        let date: Date?
        let size: Int
        let host: String
        var id: URL { url }
    }

    @State private var files: [Snapshot] = []
    @State private var selection: URL?
    @State private var preview = ""
    @State private var loadingPreview = false
    @State private var onlyThisRouter = true

    private var selected: Snapshot? {
        guard let selection else { return nil }
        return files.first { $0.url == selection }
    }

    private var visible: [Snapshot] {
        guard onlyThisRouter else { return files }
        let mine = Backups.safeHost(session.router.host)
        return files.filter { $0.host == mine }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            list
                .frame(width: 340)
            detail
        }
        .padding(20)
        .onAppear(perform: reload)
        .onChange(of: session.router.id) { _, _ in
            // Снимки лежат вперемешку, и выделенный принадлежал прошлому
            // роутеру — под фильтром «только этот» он просто исчезал бы.
            if onlyThisRouter, let selection,
               !visible.contains(where: { $0.url == selection }) { clearSelection() }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeader(icon: "clock.arrow.circlepath", title: "Резервные копии",
                           subtitle: "Снимаются автоматически перед каждым изменением")
                Spacer()
                Button {
                    NSWorkspace.shared.open(AppPaths.backups)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Открыть папку")
            }

            HStack(spacing: 8) {
                Button("Снять копию сейчас") { Task { await snapshot() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(session.progress != nil)
                Button("Обновить") { reload() }
                    .buttonStyle(SubtleButtonStyle())
            }

            Toggle(isOn: $onlyThisRouter) {
                Text("Только «\(session.router.name)»")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .help("Снимки всех роутеров лежат в одной папке — фильтр оставляет только этот")

            if visible.isEmpty {
                EmptyHint(icon: "tray", title: files.isEmpty ? "Копий пока нет" : "Для этого роутера копий нет",
                          message: files.isEmpty
                            ? "Первая появится перед первым изменением конфигурации."
                            : "Сними копию сейчас или сними галочку, чтобы увидеть остальные.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { item in
                            row(item)
                            if item.id != visible.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .inset()
            }
        }
        .card()
    }

    private func row(_ item: Snapshot) -> some View {
        let selected = selection == item.url

        return HStack(spacing: 9) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(selected ? Palette.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.date.map(Format.humanDate) ?? item.url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(item.host.isEmpty ? "—" : item.host) · \(Format.bytes(item.size))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Palette.accent.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .help(item.url.lastPathComponent)
        .onTapGesture { select(item.url) }
        .contextMenu {
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Скопировать путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Button("Удалить", role: .destructive) {
                try? FileManager.default.removeItem(at: item.url)
                if selection == item.url { clearSelection() }
                reload()
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeader(icon: "doc.plaintext",
                           title: selected.map { $0.date.map(Format.humanDate) ?? $0.url.lastPathComponent }
                             ?? "Содержимое копии",
                           subtitle: selected.map { "running-config · \($0.host) · \($0.url.lastPathComponent)" }
                             ?? "Выбери файл слева")
                Spacer()
                if !preview.isEmpty {
                    Button("Копировать") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(preview, forType: .string)
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
            }

            if loadingPreview {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Читаю файл…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if preview.isEmpty {
                EmptyHint(icon: "doc.text.magnifyingglass", title: "Ничего не выбрано",
                          message: "Слева — все снимки конфигурации. Здесь будет их содержимое.")
            } else {
                ScrollView {
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .inset()
            }
        }
        .card()
    }

    private func reload() {
        files = Backups.list().map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Snapshot(url: url,
                            date: values?.contentModificationDate,
                            size: values?.fileSize ?? 0,
                            host: Backups.host(of: url))
        }
        if let selection, !files.contains(where: { $0.url == selection }) { clearSelection() }
    }

    private func clearSelection() {
        selection = nil
        preview = ""
        loadingPreview = false
    }

    /// Конфигурация бывает и на мегабайт — читаем её не на главном потоке.
    private func select(_ url: URL) {
        selection = url
        preview = ""
        loadingPreview = true
        Task {
            let text = await Task.detached {
                (try? String(contentsOf: url, encoding: .utf8)) ?? "Файл не читается."
            }.value
            guard selection == url else { return }
            preview = text
            loadingPreview = false
        }
    }

    private func snapshot() async {
        do {
            let text = try await session.readConfigText()
            let url = Backups.saveRunningConfig(host: session.router.host, text: text,
                                                keep: Store.shared.settings.keepBackups)
            log(.ok, "Снимок конфигурации: \(url?.lastPathComponent ?? "не сохранён")")
            reload()
            if let url { select(url) }
        } catch {
            alert = AlertPayload(title: "Не удалось снять копию", message: session.describe(error))
        }
    }
}
