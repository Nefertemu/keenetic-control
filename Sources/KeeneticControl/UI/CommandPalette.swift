import SwiftUI

/// Переход к нужному месту в обход боковой панели.
///
/// Пятнадцать списков, десяток интерфейсов и три роутера — искать их
/// глазами по экранам дольше, чем набрать три буквы. Палитра ничего не
/// меняет на роутере: она только переключает экран, роутер или подставляет
/// фильтр.
@MainActor
final class Navigator: ObservableObject {
    static let shared = Navigator()

    /// Фильтр, который подхватит экран маршрутов при открытии.
    @Published var listQuery: String?
    /// Интерфейс, который выберет экран WireGuard.
    @Published var interfaceIdent: String?
    /// Палитру открывает пункт меню — оттуда до состояния окна не дотянуться.
    @Published var paletteRequested = false
    /// Вкладка раздела «Туннели», на которую нужно перейти.
    @Published var tunnelsTab: TunnelsTab?

    private init() {}

    /// Забрать значение и сразу очистить: переход одноразовый, иначе он
    /// повторялся бы при каждом возврате на экран.
    func takeListQuery() -> String? {
        defer { listQuery = nil }
        return listQuery
    }

    func takeInterface() -> String? {
        defer { interfaceIdent = nil }
        return interfaceIdent
    }
}

struct PaletteItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case section(AppSection)
        case router(UUID)
        case list(String)
        case interfaceItem(String)
    }

    let id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var icon: String
    var group: String
}

struct CommandPalette: View {
    let items: [PaletteItem]
    var onPick: (PaletteItem) -> Void
    var onCancel: () -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [PaletteItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Array(items.prefix(30)) }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.subtitle.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Группы в том же порядке, в каком идут элементы, — без сортировки по
    /// алфавиту: разделы должны оставаться сверху.
    private var groups: [String] {
        var seen: [String] = []
        for item in matches where !seen.contains(item.group) { seen.append(item.group) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField("Раздел, роутер, список или интерфейс", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit {
                        if let first = matches.first { onPick(first) }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            if matches.isEmpty {
                Text("Ничего не нашлось")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.self) { group in
                            Text(group)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 3)

                            ForEach(matches.filter { $0.group == group }) { item in
                                row(item)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 380)
            }

            Divider()

            HStack(spacing: 10) {
                Text("Enter — перейти к первому · Esc — закрыть")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("ничего не меняется на роутере")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .frame(width: 560)
        .background(Palette.surface)
        .onAppear { focused = true }
        .onExitCommand(perform: onCancel)
    }

    private func row(_ item: PaletteItem) -> some View {
        Button {
            onPick(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
