import SwiftUI

struct RouteExplanationView: View {
    @EnvironmentObject private var session: RouterSession
    @State private var query = ""
    @StateObject private var reading = RouteExplanationController()

    private var scope: RouteExplanationScope {
        RouteExplanationScope(router: RouterPresentationContext(session.router),
                              query: query, readAt: session.state?.readAt)
    }

    var body: some View {
        RouteExplanationContent(
            query: $query, hasState: session.state != nil,
            snapshotLabel: session.state.map { "\(session.router.name) · прочитано \(Format.age($0.readAt))" },
            isRunning: reading.isRunning, report: reading.report, error: reading.error,
            onSearch: search,
            onDiagnostics: { Navigator.shared.tunnelsTab = .diagnostics })
            .onChange(of: scope) { _, current in reading.invalidate(for: current) }
            .onReceive(Navigator.shared.$routeQuery) { value in
                guard let value else { return }
                // @Published delivers from willSet. Consume on the next actor
                // turn, otherwise the enclosing setter restores the old query.
                Task { @MainActor in
                    guard Navigator.shared.routeQuery == value else { return }
                    Navigator.shared.routeQuery = nil
                    query = value
                    search()
                }
            }
            .onDisappear { reading.reset() }
    }

    private func search() {
        guard let state = session.state else { return }
        reading.search(scope: scope, state: state)
    }
}

/// Kept separate from the session so every visible state can be exercised
/// with real SwiftUI rendering without connecting to a router.
struct RouteExplanationContent: View {
    @Binding var query: String
    var hasState = true
    var snapshotLabel: String?
    var isRunning = false
    var report: RouteExplanationReport?
    var error: String?
    var onSearch: () -> Void = {}
    var onDiagnostics: () -> Void = {}

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                controls
                if !hasState {
                    EmptyHint(icon: "wifi.router", title: "Сначала прочитай роутер",
                              message: "Подключись и нажми «Обновить». Поиск объяснит правила из прочитанной конфигурации.")
                        .card()
                } else if isRunning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Ищу совпадения в конфигурации…").font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                } else if let report {
                    summary(report)
                    ForEach(report.groups) { group in
                        RouteExplanationGroupCard(group: group)
                    }
                    if !report.staticRoutes.isEmpty { staticRoutes(report) }
                    limits(report)
                } else {
                    EmptyHint(icon: "point.topleft.down.to.point.bottomright.curvepath",
                              title: "Почему выбран этот маршрут?",
                              message: "Найди списки, подсети и интерфейсы для домена или IP. Можно вставить ссылку целиком.")
                        .card()
                }
            }
            .padding(20)
        }
        .frame(minWidth: 320)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "magnifyingglass", title: "Поиск маршрута",
                       subtitle: "Объяснение по конфигурации выбранного роутера")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { field; searchButton }
                VStack(alignment: .leading, spacing: 10) { field; searchButton }
            }
            if let snapshotLabel {
                Text(snapshotLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(snapshotLabel)
            }
            Text("Поиск работает без сетевых запросов и ничего не меняет на роутере.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .card()
    }

    private var field: some View {
        TextField("Домен, URL или IP: example.org", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 210, maxWidth: .infinity)
            .accessibilityLabel("Домен, URL или IP")
            .onSubmit { if canSearch { onSearch() } }
    }

    private var canSearch: Bool { hasState && !isRunning && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var searchButton: some View {
        Button(action: onSearch) {
            Label(isRunning ? "Поиск…" : "Найти маршрут", systemImage: "magnifyingglass")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!canSearch)
    }

    private func summary(_ report: RouteExplanationReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: report.hasMatches ? "list.bullet.rectangle" : "magnifyingglass")
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(report.query.value)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .help(report.query.value)
                    Text(report.hasMatches
                         ? "Совпавших списков: \(report.groups.count) · статических маршрутов: \(report.staticRoutes.count)"
                         : "Совпадений в прочитанной конфигурации нет")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if report.hasCompetingLists {
                explanationText("Адрес совпал с несколькими списками с маршрутами. Их правила показаны отдельно: один выбранный туннель по этому снимку определить нельзя.", warning: true)
            }
            if report.groups.count > 1 {
                explanationText("Сначала показаны более точные совпадения. Положение списка здесь не означает его приоритет на роутере.")
            }
        }
        .card()
    }

    private func staticRoutes(_ report: RouteExplanationReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "arrow.triangle.branch", title: "Статические маршруты",
                       subtitle: "Сначала — самая узкая подходящая сеть")
            if let prefix = report.longestStaticPrefix {
                explanationText("Наиболее длинный префикс среди включённых статических правил — /\(prefix). Это кандидаты по адресу; активность и политики подключения проверяются отдельно.")
            } else {
                explanationText("Все совпавшие статические правила отключены в конфигурации и не участвуют в выборе маршрута.")
            }
            ForEach(report.staticRoutes) { match in
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            staticDestination(match)
                            Spacer(minLength: 8)
                            if !match.route.disabled, match.prefix == report.longestStaticPrefix { longestPrefixBadge }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            staticDestination(match)
                            if !match.route.disabled, match.prefix == report.longestStaticPrefix { longestPrefixBadge }
                        }
                    }
                    Text(match.targetLabel)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .help(match.targetLabel)
                    HStack(spacing: 10) {
                        if match.route.disabled { StatusPill(text: "Отключён", tint: .secondary) }
                        RouteExplanationFlags(auto: match.route.auto, reject: match.route.reject)
                        if let metric = match.route.metric {
                            Text("метрика \(metric)").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Text(StaticRouteParser.exportCLI([match.route]).trimmingCharacters(in: .newlines))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .inset()
            }
        }
        .card()
    }

    private func staticDestination(_ match: RouteExplanationStaticMatch) -> some View {
        Text(match.route.destination == "default" ? "По умолчанию · /0" : match.route.destination)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .lineLimit(2)
            .textSelection(.enabled)
    }

    private var longestPrefixBadge: some View {
        Text("Наиболее точное правило")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.accent)
    }

    private func limits(_ report: RouteExplanationReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "info.circle", title: "Что ещё влияет на трафик")
            if report.query.kind == .domain {
                explanationText("IP-адреса домена здесь не запрашивались. Подсети и статические маршруты можно сравнить отдельным поиском по IP из DNS-ответа. Ответы DNS на Mac и роутере могут различаться.")
            } else {
                explanationText("Доменное имя по IP не угадывается. В списках показаны только совпавшие адреса и подсети; правила для доменов проверяются поиском по имени.")
            }
            if report.unsupportedStaticCount > 0 {
                explanationText("Не удалось разобрать статические правила: \(report.unsupportedStaticCount). Они не включены в результат; отсутствие совпадений не исключает эти маршруты.", warning: true)
            }
            explanationText("Это правила из снимка, а не измерение трафика. На фактический путь влияют DNS-кэш, состояние туннелей, приоритеты интерфейсов и политики конкретного устройства. Маршруты внутри отдельных политик здесь не сравниваются.")
            explanationText("auto — применять маршрут при доступном шлюзе. reject вместе с auto запрещает обход через другие маршруты при недоступности интерфейса; для маршрута по умолчанию reject не применяется.")
            Button(action: onDiagnostics) {
                Label("Открыть диагностику туннелей", systemImage: "stethoscope")
            }
            .buttonStyle(SubtleButtonStyle())
        }
        .card()
    }

    private func explanationText(_ text: String, warning: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(warning ? Palette.warning : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RouteExplanationGroupCard: View {
    let group: RouteExplanationGroup
    @State private var showAllEntries = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).font(.system(size: 13, weight: .semibold))
                        .lineLimit(3).help(group.name)
                    Text(group.ident).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            ForEach(showAllEntries ? group.entries : Array(group.entries.prefix(6))) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.value).font(.system(size: 11, design: .monospaced))
                        .lineLimit(2).textSelection(.enabled).help(entry.value)
                    Text(entry.reason).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if group.entries.count > 6 {
                Button(showAllEntries ? "Свернуть совпадения" : "Все совпадения (\(group.entries.count))") { showAllEntries.toggle() }
                    .buttonStyle(.link)
            }
            Divider()
            if group.steps.isEmpty && group.unparsedRules.isEmpty {
                Label("Список найден, но маршрут ему не назначен", systemImage: "minus.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Порядок направлений в конфигурации")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(group.steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(step.position)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.accent).frame(width: 18)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(step.label).font(.system(size: 12, weight: .medium))
                                .lineLimit(3).help(step.label)
                            RouteExplanationFlags(auto: step.auto, reject: step.reject)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if !group.unparsedRules.isEmpty {
                    Text("Есть правила с неподдерживаемыми параметрами. Их порядок и влияние нужно проверить на роутере.")
                        .font(.system(size: 11)).foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(group.unparsedRules.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced))
                            .lineLimit(4).textSelection(.enabled).help(line)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct RouteExplanationFlags: View {
    let auto: Bool
    let reject: Bool
    var body: some View {
        Text([auto ? "auto" : nil, reject ? "reject" : nil].compactMap { $0 }.joined(separator: " · ").isEmpty
             ? "без auto и reject"
             : [auto ? "auto" : nil, reject ? "reject" : nil].compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(reject ? Palette.warning : Color.secondary)
    }
}
