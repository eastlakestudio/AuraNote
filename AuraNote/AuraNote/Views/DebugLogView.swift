import SwiftUI
import AppKit

struct DebugLogView: View {
    @State private var log: String = ""
    @State private var timer: Timer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc("debug_log")).font(.headline)
                Spacer()
                Button(loc("refresh")) { loadLog() }
                    .buttonStyle(.bordered).controlSize(.small)
                Button { copyLog() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help(loc("copy"))
                .disabled(log.isEmpty)
                Button { clearLog() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help(loc("delete"))
                .disabled(log.isEmpty)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.isEmpty ? loc("debug_log_empty") : log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .id("bottom")
                }
                .onAppear {
                    loadLog()
                    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                        loadLog()
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onDisappear { timer?.invalidate() }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private func loadLog() {
        let logURL = Self.logFileURL
        Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: logURL),
                  let text = String(data: data, encoding: .utf8) else {
                await MainActor.run { self.log = "" }
                return
            }
            // 截取后 500 行进行主线程文本渲染，防止巨型文件卡死 SwiftUI
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let tailLines = lines.suffix(500)
            let tailText = tailLines.joined(separator: "\n")
            
            await MainActor.run {
                self.log = tailText
            }
        }
    }

    private func copyLog() {
        let logURL = Self.logFileURL
        Task.detached(priority: .userInitiated) {
            if let data = try? Data(contentsOf: logURL),
               let text = String(data: data, encoding: .utf8) {
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }
            }
        }
    }

    private func clearLog() {
        try? Data().write(to: Self.logFileURL)
        log = ""
    }

    private static var logFileURL: URL {
        SettingsManager.shared.dataDirectory
            .appendingPathComponent("debug.log")
    }
}
