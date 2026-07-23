import SwiftUI
#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单进程锁：如果发现同 Bundle ID 的其他进程已在运行，则唤醒它并退出当前进程
        if let bundleId = Bundle.main.bundleIdentifier {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if runningApps.count > 1 {
                for app in runningApps where app != NSRunningApplication.current {
                    app.activate(options: [.activateIgnoringOtherApps])
                    break
                }
                NSApp.terminate(nil)
                return
            }
        }

        // 移除不必要的系统菜单，仅保留 App 菜单（关于、退出等）
        guard let mainMenu = NSApp.mainMenu else { return }
        let toRemove = ["File", "Edit", "View", "Format", "Window", "Help"]
        let itemsToRemove = mainMenu.items.filter { toRemove.contains($0.title) }
        for item in itemsToRemove {
            mainMenu.removeItem(item)
        }
    }
}
#endif

@main
struct AuraNoteApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    @State private var databaseManager = DatabaseManager()

    var body: some Scene {
        Window("AuraNote", id: "main") {
            ContentView()
                .frame(minWidth: 960, minHeight: 760)
                .environment(databaseManager)
                .task {
                    // 启动时预加载语音模型，避免进入录音界面后才阻塞等待
                    do {
                        try await WhisperService.shared.initialize()
                        AppLog.info("Voice model preload completed on startup")
                    } catch {
                        AppLog.error("Voice model preload failed on startup: \(error.localizedDescription)")
                    }
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于听纪") {
                    showAboutWindow()
                }
            }
        }
    }

    #if os(macOS)
    private func showAboutWindow() {
        // 已存在则前置
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "about" }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        // 新建 About 窗口
        let aboutVC = NSHostingController(rootView: AboutView().background(.regularMaterial))
        let aboutWindow = NSWindow(contentViewController: aboutVC)
        aboutWindow.identifier = NSUserInterfaceItemIdentifier("about")
        aboutWindow.title = "关于听纪"
        aboutWindow.styleMask = [.titled, .closable]
        aboutWindow.setContentSize(NSSize(width: 460, height: 440))
        aboutWindow.center()
        aboutWindow.makeKeyAndOrderFront(nil)
    }
    #endif
}
