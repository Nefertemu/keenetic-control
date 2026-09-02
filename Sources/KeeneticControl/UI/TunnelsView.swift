import SwiftUI

/// Всё про туннели в одном разделе.
///
/// Раньше WireGuard, Ping-Check и Диагностика были тремя пунктами боковой
/// панели, хотя говорят про один и тот же объект: выбрал туннель — и
/// смотришь его состояние, правишь проверку связи или разбираешься, почему
/// не ходит трафик. Экран WireGuard при этом складывал в одну прокрутку и
/// наблюдение, и опасное обновление конфига — теперь это разные вкладки.
struct TunnelsView: View {
    @EnvironmentObject private var session: RouterSession
    @Binding var alert: AlertPayload?
    @Binding var section: AppSection
    @Binding var tab: TunnelsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(TunnelsTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Text(tab.explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 6)

            switch tab {
            case .status:
                WireGuardView(alert: $alert, section: $section, mode: .status)
            case .update:
                WireGuardView(alert: $alert, section: $section, mode: .update)
            case .pingCheck:
                PingCheckView(alert: $alert)
            case .diagnostics:
                DiagnosticsView(alert: $alert)
            }
        }
    }
}

enum TunnelsTab: String, CaseIterable, Identifiable {
    case status
    case update
    case pingCheck
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status:      return "Состояние"
        case .update:      return "Обновление"
        case .pingCheck:   return "Ping-Check"
        case .diagnostics: return "Диагностика"
        }
    }

    var explanation: String {
        switch self {
        case .status:
            return "Наблюдение: связь, задержки и история. Ничего не меняется."
        case .update:
            return "Замена конфигурации туннеля с резервной копией и откатом."
        case .pingCheck:
            return "Профили проверки связи и их назначение на интерфейсы."
        case .diagnostics:
            return "Почему трафик не идёт: DNS, маршрут и MTU. Только чтение."
        }
    }
}

/// Какую половину экрана WireGuard показывать.
enum WireGuardMode {
    case status
    case update
}
