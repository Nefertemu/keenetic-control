import SwiftUI

@main
struct KeeneticControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log(.info, "Keenetic Control запущен.")
    }
}
