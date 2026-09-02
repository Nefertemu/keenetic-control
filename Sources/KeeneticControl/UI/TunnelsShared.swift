import SwiftUI

/// Общие для вкладок «Туннели» пустые состояния и выбор интерфейса.
enum TunnelsEmptyState {
    static var notConnected: some View {
        EmptyHint(icon: "bolt.horizontal.circle", title: "Роутер не прочитан",
                  message: "Подключись и нажми «Обновить» — здесь появятся WireGuard-интерфейсы.")
            .card(padding: 24)
    }

    static var noInterfaces: some View {
        EmptyHint(icon: "shield.slash", title: "WireGuard-интерфейсов нет",
                  message: "Создай интерфейс Wireguard в веб-панели Keenetic — "
                         + "приложение обновляет существующие, но не создаёт новые.")
            .card(padding: 24)
    }
}

/// Выбор туннеля. На вкладке состояния он встроен в карточку интерфейса,
/// а на вкладке обновления нужен отдельно.
struct TunnelInterfacePicker: View {
    @EnvironmentObject private var session: RouterSession
    @Binding var interfaceIdent: String
    let interfaces: [String]

    var body: some View {
        HStack(spacing: 10) {
            CardHeader(icon: "shield.lefthalf.filled",
                       title: session.state?.shortLabel(for: interfaceIdent) ?? interfaceIdent,
                       subtitle: interfaceIdent.isEmpty ? nil : interfaceIdent)
            Spacer(minLength: 8)
            Picker("", selection: $interfaceIdent) {
                ForEach(interfaces, id: \.self) { ident in
                    Text(session.state?.label(for: ident) ?? ident).tag(ident)
                }
            }
            .labelsHidden()
            .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)
        }
        .card()
    }
}
