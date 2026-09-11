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

    /// Planner считает пробел, двоеточие, подчёркивание и дефис
    /// взаимозаменяемыми в описании группы. Для проверки владения
    /// источниками приводим префиксы к той же форме, иначе «my list» и
    /// «my-list» начнут управлять одним списком.
    static func canonicalPrefix(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[\\s:_-]+", with: " ", options: .regularExpression)
            .lowercased()
    }

    /// Имена источников, которым один и тот же список на роутере мог бы
    /// показаться «своим». Нужна не только редактору: старый файл настроек
    /// уже может содержать такую пару.
    static func conflictingSourceTitles(_ specs: [SourceSpec]) -> [String] {
        var visited = Set<Int>()
        var conflicts: [String] = []
        for index in specs.indices where !visited.contains(index) {
            var component = [index]
            visited.insert(index)
            var cursor = 0
            while cursor < component.count {
                let current = component[cursor]
                cursor += 1
                for candidate in specs.indices where !visited.contains(candidate)
                    && prefixesOverlap(specs[current], specs[candidate]) {
                    visited.insert(candidate)
                    component.append(candidate)
                }
            }
            if component.count > 1 {
                conflicts.append(component.map { specs[$0].title }.sorted().joined(separator: " / "))
            }
        }
        return conflicts.sorted()
    }

    /// «Example 2» — одновременно первая часть одноимённого источника и
    /// вторая часть «Example». Проверяем также будущие части, даже если
    /// конфликтующего списка ещё нет на роутере.
    private static func prefixesOverlap(_ lhs: SourceSpec, _ rhs: SourceSpec) -> Bool {
        let left = canonicalPrefix(lhs.descriptionPrefix)
        let right = canonicalPrefix(rhs.descriptionPrefix)
        func isNumberedPart(_ description: String, of prefix: String) -> Bool {
            let start = prefix + " "
            guard description.hasPrefix(start) else { return false }
            let suffix = description.dropFirst(start.count)
            return !suffix.isEmpty && suffix.utf8.allSatisfy { (48...57).contains($0) }
        }
        // Канонизируем обе стороны: «my-list» и «my list 2» могут пересечься
        // в описании «my-list 2», хотя исходные префиксы написаны по-разному.
        return left == right || isNumberedPart(left, of: right) || isNumberedPart(right, of: left)
    }

    static func validate(_ source: CustomSource, existing: [CustomSource]) throws {
        let title = source.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { throw TransportError("Дай источнику название.") }

        let prefix = source.descriptionPrefix.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else {
            throw TransportError("Укажи префикс описания — по нему приложение "
                                 + "узнаёт свои списки на роутере.")
        }
        guard !prefix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TransportError("Префикс описания не может содержать переводы строк "
                                 + "или управляющие символы.")
        }
        // Совпадение префикса означало бы, что два источника считают одни и те
        // же списки роутера своими и будут затирать записи друг друга.
        let taken = SourceCatalog.all + existing.filter { $0.id != source.id }.map(\.spec)
        var cleaned = source
        cleaned.descriptionPrefix = prefix
        guard !taken.contains(where: { prefixesOverlap(cleaned.spec, $0) }) else {
            throw TransportError("Префикс «\(prefix)» совпадает с другим источником или номером его части.",
                                 hint: "Иначе два источника будут спорить за одни и те же "
                                     + "списки на роутере.")
        }

        guard !source.urls.isEmpty else { throw TransportError("Укажи хотя бы один адрес или файл.") }
        for address in source.urls + source.subnetURLs {
            try validateAddress(address)
        }
    }

    private static func validateAddress(_ address: String) throws {
        guard !address.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TransportError("Адрес источника содержит перевод строки или служебный символ.")
        }
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
        guard url.user == nil, url.password == nil else {
            throw TransportError("Адрес источника не должен содержать логин или пароль.",
                                 hint: "Секреты хранятся отдельно и не попадут в журнал загрузки.")
        }
        if scheme == "http" || scheme == "https" {
            guard url.host != nil else {
                throw TransportError("В адресе источника не найден сервер: \(address)")
            }
        }
        if scheme == "file" {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TransportError("Файла нет: \(url.path)")
            }
        }
    }
}
