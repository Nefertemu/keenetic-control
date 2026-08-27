import AppKit
import SwiftUI

struct BackupsView: View {
    @EnvironmentObject private var session: RouterSession
    @Binding var alert: AlertPayload?

    @State private var files: [URL] = []
    @State private var selection: URL?
    @State private var preview = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            list
                .frame(width: 340)
            detail
        }
        .padding(20)
        .onAppear(perform: reload)
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

            if files.isEmpty {
                EmptyHint(icon: "tray", title: "Копий пока нет",
                          message: "Первая появится перед первым изменением конфигурации.")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(files, id: \.self) { url in
                            row(url)
                            if url != files.last { Divider() }
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

    private func row(_ url: URL) -> some View {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? Int) ?? 0
        let selected = selection == url

        return HStack(spacing: 9) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(selected ? Palette.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(date.map(Format.humanDate) ?? "—") · \(Format.bytes(size))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Palette.accent.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { select(url) }
        .contextMenu {
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Удалить", role: .destructive) {
                try? FileManager.default.removeItem(at: url)
                reload()
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "doc.plaintext",
                       title: selection?.lastPathComponent ?? "Содержимое копии",
                       subtitle: selection == nil ? "Выбери файл слева" : "running-config на момент снимка")

            if preview.isEmpty {
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
        files = Backups.list()
        if let selection, !files.contains(selection) {
            self.selection = nil
            preview = ""
        }
    }

    private func select(_ url: URL) {
        selection = url
        preview = (try? String(contentsOf: url, encoding: .utf8)) ?? "Файл не читается."
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
