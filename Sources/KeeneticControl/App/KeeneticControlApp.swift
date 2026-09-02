import SwiftUI

@main
struct KeeneticControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var session = RouterSession(
        router: Store.shared.selectedRouter ?? RouterProfile())

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .frame(minWidth: 1080, minHeight: 700)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Открыть папку с данными") {
                    NSWorkspace.shared.open(AppPaths.support)
                }
                Button("Открыть папку с бэкапами") {
                    NSWorkspace.shared.open(AppPaths.backups)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Соединения живут дольше переключения роутера — закрываем их явно.
    @MainActor static var session: RouterSession?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // История туннелей пишется с задержкой — досохраняем накопленное,
            // иначе последние минуты наблюдений пропали бы при выходе.
            TunnelHealthStore.shared.flush()
            AppDelegate.session?.disconnectAll()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log(.info, "Keenetic Control запущен.")
    }
}
