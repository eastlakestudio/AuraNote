import Foundation
import OSLog

/// 统一日志工具：OSLog 输出到 Console.app + 追加写入 Documents/debug.log（供 DebugLogView 展示）
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.eastlakestudio.AuraNote"

    private static let logger = Logger(subsystem: subsystem, category: "app")

    private static let queue = DispatchQueue(label: "app.log.q")

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - 公开 API

    static func info(_ message: String, file: String = #file, function: String = #function) {
        log(level: .info, message: message, file: file, function: function)
    }

    static func warn(_ message: String, file: String = #file, function: String = #function) {
        log(level: .warn, message: message, file: file, function: function)
    }

    static func error(_ message: String, file: String = #file, function: String = #function) {
        log(level: .error, message: message, file: file, function: function)
    }

    // MARK: - 内部实现

    private enum LogLevel { case info, warn, error }

    private static func log(level: LogLevel, message: String, file: String, function: String) {
        let fileName = (file as NSString).lastPathComponent
        let time = dateFormatter.string(from: Date())
        let formatted = "[\(time)] [\(fileName):\(function)] \(message)"

        // 1. OSLog 输出（Console.app 可按 subsystem/category 过滤）
        switch level {
        case .info:
            logger.info("\(formatted, privacy: .public)")
        case .warn:
            logger.warning("\(formatted, privacy: .public)")
        case .error:
            logger.error("\(formatted, privacy: .public)")
        }

        // 2. 追加写入 debug.log（供 DebugLogView 展示）
        let levelStr: String = {
            switch level {
            case .info: return "INFO"
            case .warn: return "WARN"
            case .error: return "ERROR"
            }
        }()
        let line = "[\(levelStr)] \(formatted)\n"
        print(line, terminator: "")

        queue.async {
            let logURL = SettingsManager.shared.dataDirectory
                .appendingPathComponent("debug.log")
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: logURL, options: .atomic)
            }
        }
    }
}
