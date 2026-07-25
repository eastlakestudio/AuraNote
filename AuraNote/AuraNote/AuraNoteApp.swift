import SwiftUI
#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 清空上次运行日志
        AppLog.clearLogFile()

        // 单进程锁：如果发现同 Bundle ID 的其他进程已在运行，则唤醒它并退出当前进程
        if let bundleId = Bundle.main.bundleIdentifier {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if runningApps.count > 1 {
                for app in runningApps where app != NSRunningApplication.current {
                    if #available(macOS 14.0, *) {
                        app.activate()
                    } else {
                        app.activate(options: .activateIgnoringOtherApps)
                    }
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

        // 禁用工具栏右键菜单（Icon and Text / Icon Only）
        // 方案：用 NSEvent 本地监听器拦截工具栏区域的右键点击事件
        // NSToolbar.allowsUserCustomization 只能禁用"自定义工具栏"弹窗，
        // 但 "Icon and Text/Icon Only" 是 NSWindow 级别的行为，需在事件层拦截。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow,
                  let toolbar = window.toolbar else { return }
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            toolbar.displayMode = .iconOnly
        }

        // 拦截工具栏区域右键点击，阻止系统弹出 "Icon and Text / Icon Only" 菜单
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let window = event.window else { return event }
            // contentLayoutRect 是内容区在窗口坐标系中的矩形（工具栏以下部分）
            // 若点击 Y > contentLayoutRect.maxY 则说明点击在工具栏区域
            let clickY = event.locationInWindow.y
            let contentMaxY = window.contentLayoutRect.maxY
            if clickY > contentMaxY {
                return nil   // 吞掉右键事件，不弹菜单
            }
            return event
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
                    // 启动时预加载 FunASR 语音模型
                    let settings = SettingsManager.shared
                    await FunASRService.shared.updateModelPaths(
                        online: settings.funasrOnlineModelDir,
                        offline: settings.funasrOfflineModelDir,
                        punct: settings.funasrPunctModelPath,
                        vad: settings.funasrVadModelPath
                    )

                    do {
                        if settings.isFunASROfflineAvailable {
                            try await FunASRService.shared.initializeOffline()
                        }
                        if settings.isFunASRPunctAvailable {
                            try? await FunASRService.shared.initializePunctuation()
                        }
                        // VAD 模型按需初始化（轻量 628KB），不在启动时加载
                        AppLog.info("FunASR model preload completed on startup")
                    } catch {
                        AppLog.error("FunASR preload failed: \(error)")
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
