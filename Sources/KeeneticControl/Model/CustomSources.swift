import Foundation

/// Свой источник доменов: адрес в интернете или файл на диске.
/// Встроенный каталог зашит в код и общий для всех, а это — личные списки.
struct CustomSource: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String = ""
    /// Префикс описания списка на роутере — по нему приложение потом
    /// находит «свои» части и пополняет именно их.
    var descriptionPrefix: String = ""
    /// Зеркала ОДНОГО списка: пробуются по очереди до первого удачного.
    var urls: [String] = []
    var subnetURLs: [String] = []
    /// Ниже этого числа записей загрузка считается неудачной. У личного
    /// списка их бывает и пять, поэтому по умолчанию порога почти нет.
    var minDomains: Int = 1

    var spec: SourceSpec {
        SourceSpec(
            key: "custom-\(id.uuidString)",
            title: title.isEmpty ? "Без названия" : title,
            subtitle: CustomSource.subtitle(for: urls),
            descriptionPrefix: descriptionPrefix,
            icon: urls.contains { $0.hasPrefix("/") || $0.hasPrefix("file:") }
                ? "doc.text" : "link",
            urls: urls,
            cacheName: "custom-\(id.uuidString).txt",
            subnetURLs: subnetURLs,
            minDomains: max(1, minDomains))
    }

    /// Короткая подпись под названием — откуда берётся список.
    static func subtitle(for urls: [String]) -> String {
        guard let first = urls.first, !first.isEmpty else { return "адрес не указан" }
        let extra = urls.count > 1 ? " · зеркал: \(urls.count - 1)" : ""
        if first.hasPrefix("/") { return (first as NSString).lastPathComponent + extra }
        if let host = URL(string: first)?.host { return host + extra }
        return first + extra
    }

    /// Разбор многострочного поля ввода в список адресов.
    static func addresses(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func validate(_ source: CustomSource, existing: [CustomSource]) throws {
        let title = source.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { throw TransportError("Дай источнику название.") }

        let prefix = source.descriptionPrefix.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else {
            throw TransportError("Укажи префикс описания — по нему приложение "
                                 + "узнаёт свои списки на роутере.")
        }
        // Совпадение префикса означало бы, что два источника считают одни и те
        // же списки роутера своими и будут затирать записи друг друга.
        let taken = SourceCatalog.all.map(\.descriptionPrefix)
            + existing.filter { $0.id != source.id }.map(\.descriptionPrefix)
        guard !taken.contains(where: { $0.caseInsensitiveCompare(prefix) == .orderedSame }) else {
            throw TransportError("Префикс «\(prefix)» уже занят другим источником.",
                                 hint: "Иначе два источника будут спорить за одни и те же "
                                     + "списки на роутере.")
        }

        guard !source.urls.isEmpty else { throw TransportError("Укажи хотя бы один адрес или файл.") }
        for address in source.urls + source.subnetURLs {
            try validateAddress(address)
        }
    }

    private static func validateAddress(_ address: String) throws {
        if address.hasPrefix("/") {
            guard FileManager.default.fileExists(atPath: address) else {
                throw TransportError("Файла нет: \(address)")
            }
            return
        }
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else {
            throw TransportError("Непонятный адрес: \(address)",
                                 hint: "Ожидается http://, https:// или путь к файлу от корня.")
        }
        guard ["http", "https", "file"].contains(scheme) else {
            throw TransportError("Схема \(scheme):// не поддерживается: \(address)")
        }
        if scheme == "file" {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TransportError("Файла нет: \(url.path)")
            }
        }
    }
}
