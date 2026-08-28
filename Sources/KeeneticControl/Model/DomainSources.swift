import Foundation

struct SourceSpec: Identifiable, Hashable {
    let key: String
    let title: String
    let subtitle: String
    /// Префикс описания списка на роутере — по нему находим «свои» части.
    let descriptionPrefix: String
    let icon: String
    /// Зеркала ОДНОГО списка доменов.
    let urls: [String]
    let cacheName: String
    /// Списки подсетей — складываются вместе с доменами.
    let subnetURLs: [String]
    let minDomains: Int

    var id: String { key }

    init(key: String, title: String, subtitle: String, descriptionPrefix: String,
         icon: String, urls: [String], cacheName: String,
         subnetURLs: [String] = [], minDomains: Int = 50) {
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.descriptionPrefix = descriptionPrefix
        self.icon = icon
        self.urls = urls
        self.cacheName = cacheName
        self.subnetURLs = subnetURLs
        self.minDomains = minDomains
    }

    var cacheFile: URL { AppPaths.cache.appendingPathComponent(cacheName) }
    var subnetCacheFile: URL { AppPaths.cache.appendingPathComponent("subnets-\(key).txt") }

    var domainURLs: [String] { urls.map(SourceSpec.rawGitHub) }
    var rawSubnetURLs: [String] { subnetURLs.map(SourceSpec.rawGitHub) }

    /// github.com/…/blob/… — это HTML-страница. Переводим в raw.
    static func rawGitHub(_ url: String) -> String {
        guard !url.hasPrefix("/"), !url.hasPrefix("file:") else { return url }
        guard url.contains("github.com/") else { return url }
        if url.contains("/raw/refs/heads/") { return url }
        guard url.contains("/blob/") else { return url }
        return url
            .replacingOccurrences(of: "://github.com/", with: "://raw.githubusercontent.com/")
            .replacingOccurrences(of: "/blob/", with: "/")
    }
}

enum SourceCatalog {
    private static let itdog = "https://raw.githubusercontent.com/itdoginfo/allow-domains/main"

    static let all: [SourceSpec] = [
        SourceSpec(
            key: "hoaxisr",
            title: "Недоступные из России",
            subtitle: "hoaxisr/rulesets · unavailable-in-russia",
            descriptionPrefix: "hoaxisr ru block",
            icon: "globe.badge.chevron.backward",
            urls: [
                "https://raw.githubusercontent.com/hoaxisr/rulesets/master/raw/unavailable-in-russia.txt",
                "https://github.com/hoaxisr/rulesets/raw/refs/heads/master/raw/unavailable-in-russia.txt",
            ],
            cacheName: "hoaxisr-unavailable-in-russia.txt"),

        SourceSpec(
            key: "itdog_inside",
            title: "Заблокированные внутри России",
            subtitle: "itdoginfo/allow-domains · Russia/inside-raw",
            descriptionPrefix: "itdog ru inside",
            icon: "lock.shield",
            urls: [
                "\(itdog)/Russia/inside-raw.lst",
                "https://github.com/itdoginfo/allow-domains/raw/refs/heads/main/Russia/inside-raw.lst",
            ],
            cacheName: "itdog-russia-inside-raw.lst"),

        SourceSpec(
            key: "kinopub",
            title: "KinoPub",
            subtitle: "Ground-Zerro/Geo-Aggregator",
            descriptionPrefix: "kinopub",
            icon: "film",
            urls: ["https://raw.githubusercontent.com/Ground-Zerro/Geo-Aggregator/main/source1/kinopub.txt"],
            cacheName: "kinopub.txt",
            minDomains: 5),

        SourceSpec(
            key: "telegram",
            title: "Telegram",
            subtitle: "itdoginfo · домены и подсети",
            descriptionPrefix: "telegram",
            icon: "paperplane.fill",
            urls: ["\(itdog)/Services/telegram.lst"],
            cacheName: "itdog-telegram.lst",
            subnetURLs: ["\(itdog)/Subnets/IPv4/telegram.lst", "\(itdog)/Subnets/IPv6/telegram.lst"],
            minDomains: 5),

        SourceSpec(
            key: "meta",
            title: "Meta",
            subtitle: "Instagram, Facebook, WhatsApp · домены и подсети",
            descriptionPrefix: "meta",
            icon: "camera.macro",
            urls: ["\(itdog)/Services/meta.lst"],
            cacheName: "itdog-meta.lst",
            subnetURLs: ["\(itdog)/Subnets/IPv4/meta.lst", "\(itdog)/Subnets/IPv6/Meta.lst"],
            minDomains: 5),

        SourceSpec(
            key: "twitter",
            title: "Twitter / X",
            subtitle: "itdoginfo · домены и подсети",
            descriptionPrefix: "twitter",
            icon: "bird",
            urls: ["\(itdog)/Services/twitter.lst"],
            cacheName: "itdog-twitter.lst",
            subnetURLs: ["\(itdog)/Subnets/IPv4/twitter.lst", "\(itdog)/Subnets/IPv6/twitter.lst"],
            minDomains: 5),

        SourceSpec(
            key: "twitch",
            title: "Twitch",
            subtitle: "Ground-Zerro/Geo-Aggregator",
            descriptionPrefix: "twitch",
            icon: "gamecontroller",
            urls: ["https://raw.githubusercontent.com/Ground-Zerro/Geo-Aggregator/main/source2/twitch.txt"],
            cacheName: "twitch.txt",
            minDomains: 5),

        SourceSpec(
            key: "discord",
            title: "Discord",
            subtitle: "itdoginfo · домены и подсети",
            descriptionPrefix: "discord",
            icon: "bubble.left.and.bubble.right.fill",
            urls: ["\(itdog)/Services/discord.lst"],
            cacheName: "itdog-discord.lst",
            subnetURLs: ["\(itdog)/Subnets/IPv4/Discord.lst", "\(itdog)/Subnets/IPv6/Discord.lst"],
            minDomains: 5),
    ]

    static func spec(for key: String) -> SourceSpec? { all.first { $0.key == key } }
}

struct SourceData {
    let spec: SourceSpec
    /// Домены и подсети одним списком — Keenetic кладёт их в одну object-group.
    let entries: [String]
    let fromCache: Bool
    let fetchedAt: Date?
    let skipped: [String]
    let duplicates: Int
    let subnetsV4: [String]
    let subnetsV6: [String]

    var subnetCount: Int { subnetsV4.count + subnetsV6.count }
    var domainCount: Int { entries.count - subnetCount }

    var freshness: String {
        guard let fetchedAt else { return "неизвестно когда" }
        return Format.age(fetchedAt) + (fromCache ? " · из кэша" : "")
    }
}

enum SourceLoader {
    /// Скачивает список (с зеркалами), при неудаче честно берёт локальную копию.
    static func load(_ spec: SourceSpec, ttlMinutes: Int, forceRefresh: Bool) throws -> SourceData {
        let (v4, v6) = loadSubnets(spec, ttlMinutes: ttlMinutes, forceRefresh: forceRefresh)

        func finish(_ parsed: Domains.ParseResult, fromCache: Bool, at moment: Date?) -> SourceData {
            var seen = Set(parsed.domains)
            var merged = parsed.domains
            for entry in v4 + v6 where !seen.contains(entry) {
                seen.insert(entry)
                merged.append(entry)
            }
            return SourceData(
                spec: spec, entries: merged, fromCache: fromCache, fetchedAt: moment,
                skipped: parsed.skipped, duplicates: parsed.duplicates,
                subnetsV4: v4, subnetsV6: v6)
        }

        let cacheFile = spec.cacheFile
        let cacheDate = (try? FileManager.default.attributesOfItem(atPath: cacheFile.path)[.modificationDate]) as? Date

        if !forceRefresh, ttlMinutes > 0, let cacheDate,
           Date().timeIntervalSince(cacheDate) / 60 < Double(ttlMinutes),
           let text = try? String(contentsOf: cacheFile, encoding: .utf8) {
            let parsed = Domains.parseList(text)
            if parsed.domains.count >= spec.minDomains {
                return finish(parsed, fromCache: true, at: cacheDate)
            }
        }

        var errors: [String] = []
        for url in spec.domainURLs {
            do {
                let text = try fetch(url)
                let parsed = Domains.parseList(text)
                guard parsed.domains.count >= spec.minDomains else {
                    errors.append("\(url): распознано только \(parsed.domains.count) записей")
                    continue
                }
                try? text.write(to: cacheFile, atomically: true, encoding: .utf8)
                return finish(parsed, fromCache: false, at: Date())
            } catch {
                errors.append("\(url): \(error.localizedDescription)")
            }
        }

        if let text = try? String(contentsOf: cacheFile, encoding: .utf8) {
            let parsed = Domains.parseList(text)
            if parsed.domains.count >= spec.minDomains {
                log(.warn, "\(spec.title): источник не ответил, беру локальную копию.")
                return finish(parsed, fromCache: true, at: cacheDate)
            }
        }

        throw TransportError(
            "Не удалось загрузить «\(spec.title)», пригодной локальной копии нет.",
            hint: errors.joined(separator: "\n"))
    }

    private static func loadSubnets(_ spec: SourceSpec, ttlMinutes: Int, forceRefresh: Bool) -> ([String], [String]) {
        guard !spec.subnetURLs.isEmpty else { return ([], []) }
        let cacheFile = spec.subnetCacheFile

        if !forceRefresh, ttlMinutes > 0,
           let date = (try? FileManager.default.attributesOfItem(atPath: cacheFile.path)[.modificationDate]) as? Date,
           Date().timeIntervalSince(date) / 60 < Double(ttlMinutes),
           let text = try? String(contentsOf: cacheFile, encoding: .utf8) {
            let parsed = Domains.parseSubnets(text)
            if !parsed.v4.isEmpty || !parsed.v6.isEmpty { return (parsed.v4, parsed.v6) }
        }

        var collected: [String] = []
        for url in spec.rawSubnetURLs {
            if let text = try? fetch(url) { collected.append(text) }
        }

        if !collected.isEmpty {
            let parsed = Domains.parseSubnets(collected.joined(separator: "\n"))
            if !parsed.v4.isEmpty || !parsed.v6.isEmpty {
                try? (parsed.v4 + parsed.v6).joined(separator: "\n")
                    .write(to: cacheFile, atomically: true, encoding: .utf8)
                return (parsed.v4, parsed.v6)
            }
        }

        if let text = try? String(contentsOf: cacheFile, encoding: .utf8) {
            let parsed = Domains.parseSubnets(text)
            return (parsed.v4, parsed.v6)
        }
        return ([], [])
    }

    /// Синхронная загрузка: вызывается только с фоновой очереди.
    static func fetch(_ urlString: String) throws -> String {
        // Свой источник может быть файлом на диске — читаем его напрямую,
        // а не через сеть.
        if urlString.hasPrefix("/") || urlString.hasPrefix("file:") {
            let path = urlString.hasPrefix("file:")
                ? (URL(string: urlString)?.path ?? urlString)
                : urlString
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw TransportError("Не читается файл: \(path)")
            }
            return text
        }

        guard let url = URL(string: urlString) else {
            throw TransportError("Некорректный адрес: \(urlString)")
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40)
        request.setValue("KeeneticControl/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error>?

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(TransportError("HTTP \(http.statusCode)"))
                return
            }
            guard let data else {
                result = .failure(TransportError("Пустой ответ"))
                return
            }
            var text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            result = .success(text)
        }.resume()

        semaphore.wait()

        switch result {
        case .success(let text): return text
        case .failure(let error): throw error
        case nil: throw TransportError("Загрузка не завершилась")
        }
    }
}
