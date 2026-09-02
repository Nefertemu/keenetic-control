import SwiftUI

/// Списки доменов: откуда их брать и куда направлять.
///
/// Раньше это были два отдельных пункта боковой панели, и экран загрузки
/// сам объяснял в тексте, что маршруты назначаются «на другой вкладке».
/// Если навигацию приходится объяснять словами — она неправильная: это
/// две половины одной задачи, и живут они теперь рядом.
struct DomainsView: View {
    @EnvironmentObject private var session: RouterSession
    @Binding var alert: AlertPayload?
    @Binding var tab: DomainsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(DomainsTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Text(tab.explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 6)

            switch tab {
            case .sources: FqdnView(alert: $alert)
            case .routes:  DnsRoutesView(alert: $alert)
            }
        }
    }
}

enum DomainsTab: String, CaseIterable, Identifiable {
    case sources
    case routes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: return "Источники"
        case .routes:  return "Маршруты"
        }
    }

    var explanation: String {
        switch self {
        case .sources:
            return "Шаг 1 — наполнить списки доменами. Маршруты при этом не меняются."
        case .routes:
            return "Шаг 2 — направить списки в туннели. Содержимое списков не меняется."
        }
    }
}
