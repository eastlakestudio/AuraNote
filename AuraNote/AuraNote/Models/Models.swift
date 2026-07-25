import Foundation

// MARK: - 会议记录

struct Meeting: Identifiable, Codable, Hashable {
    let id: String
    var parentMeetingId: String?
    var title: String
    var location: String?
    var audioPath: String
    var duration: Int // 秒
    var status: Status
    var summary: String?
    var createdAt: Date
    var updatedAt: Date
    var attendees: String? // 新增：空格分隔的参会人姓名列表
    var hotwordCategories: String? // 逗号分隔的分类 ID

    enum Status: String, Codable, CaseIterable {
        case recording
        case pendingDiarization = "pending_diarization"
        case processingLlm = "processing_llm"
        case completed
    }

    /// 便捷初始化：创建新会议
    static func create(
        title: String,
        location: String? = nil,
        parentMeetingId: String? = nil,
        attendees: String? = nil
    ) -> Meeting {
        let now = Date()
        return Meeting(
            id: UUID().uuidString,
            parentMeetingId: parentMeetingId,
            title: title,
            location: location,
            audioPath: "",
            duration: 0,
            status: .recording,
            summary: nil,
            createdAt: now,
            updatedAt: now,
            attendees: attendees
        )
    }
}

extension Meeting {
    /// 文件级缓存：避免计算属性在 SwiftUI 重绘时反复触发 7 次 FileManager.fileExists
    private static var _audioURLCache: [String: URL] = [:]
    
    /// 获取当前会议音频的最新绝对 URL（适配沙盒重启 UUID 变化，并动态探测后缀）
    var localAudioURL: URL {
        // 缓存命中直接返回，避免重复 I/O
        if let cached = Self._audioURLCache[id], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        
        let docDir = SettingsManager.shared.dataDirectory
        
        if !audioPath.isEmpty {
            let lastPathComponent = URL(fileURLWithPath: audioPath).lastPathComponent
            let targetURL = docDir.appendingPathComponent(lastPathComponent)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                Self._audioURLCache[id] = targetURL
                return targetURL
            }
        }
        
        let allowedExts = ["wav", "mp3", "m4a", "aac", "flac", "ogg", "caf"]
        for ext in allowedExts {
            let url = docDir.appendingPathComponent("audio_\(id).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                Self._audioURLCache[id] = url
                return url
            }
        }
        
        let fallback = docDir.appendingPathComponent("audio_\(id).wav")
        Self._audioURLCache[id] = fallback
        return fallback
    }

    var audioFileExists: Bool {
        FileManager.default.fileExists(atPath: localAudioURL.path)
    }

    var missingAudioReason: String? {
        if audioFileExists { return nil }
        let url = localAudioURL
        let docDir = SettingsManager.shared.dataDirectory
        let expectedName = "audio_\(id)"
        let files: [String]
        do {
            files = try FileManager.default.contentsOfDirectory(atPath: docDir.path)
        } catch {
            AppLog.warn("Failed to read documents directory path=\(docDir.path): \(error.localizedDescription)")
            files = []
        }
        let matching = files.filter { $0.hasPrefix(expectedName) || $0.contains(id) }
        if matching.isEmpty {
            return String(format: loc("audio_file_not_found_diag"), expectedName)
        }
        return String(format: loc("audio_file_missing_diag"), url.lastPathComponent, matching.joined(separator: ", "))
    }
}

// MARK: - 发言切片

struct SpeechClip: Identifiable, Codable, Hashable {
    let id: String
    let meetingId: String
    var speakerLabel: String       // Speaker_A, Speaker_B ... 或 '?' (尚未声纹提取/占位)
    var contactId: String?         // 绑定后的联系人 ID
    var startTime: Double          // 秒
    var endTime: Double            // 秒
    var originalText: String       // ASR 原始转写
    var cleanedText: String?       // LLM 净化后文本
    var audioClipPath: String?     // 试听音频切片路径
    var isKeyClip: Bool            // 是否为代表该 speaker 的核心切片
}

// MARK: - 联系人（声纹人脉库）

struct Contact: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var role: String?
    var company: String?
    var avatarUrl: String?
    var createdAt: Date
    var updatedAt: Date

    var displayName: String {
        if let c = company, !c.isEmpty {
            return "\(name) (\(c))"
        }
        return name
    }

    static func create(name: String, role: String? = nil, company: String? = nil) -> Contact {
        let now = Date()
        return Contact(
            id: UUID().uuidString,
            name: name,
            role: role,
            company: company,
            avatarUrl: nil,
            createdAt: now,
            updatedAt: now
        )
    }
}

// MARK: - 私域知识文档

struct KBDocument: Identifiable, Codable, Hashable {
    let id: String
    var filename: String
    var filePath: String
    var textContent: String?
    var createdAt: Date

    static func create(filename: String, filePath: String) -> KBDocument {
        KBDocument(
            id: UUID().uuidString,
            filename: filename,
            filePath: filePath,
            textContent: nil,
            createdAt: Date()
        )
    }
}

// MARK: - 实时转写片段（非持久化，用于 UI 展示）

struct TranscriptSegment: Identifiable, Hashable {
    let id: String
    let startTime: Double
    let endTime: Double
    var text: String
    var speakerLabel: String
    var contactId: String?
    var isFinal: Bool       // 是否为最终结果（非中间识别）
    var isManualEdit: Bool = false // 是否为用户手动修改过标签
    var isPlaceholder: Bool = false  // 是否为占位段（等待离线转写回填）
    /// Paraformer token 级时间戳，与 text 字符一一对应。
    /// `tokenTimestamps[i]` = text 第 i 个字符对应的音频时间（秒）。
    /// 标点字符（，。！？等）无独立时间戳，取最近非标点字符的时间戳。
    /// nil 表示无 token 级时间戳（回退模式），此时 DiarizationService 退化为按时长比例分本。
    var tokenTimestamps: [Double]? = nil
    /// 最后一个 token 的时长（秒），用于计算 sub-segment 的精确 endTime。
    /// 仅在 tokenTimestamps 非 nil 时有效。
    var lastTokenDuration: Double = 0.3

    var formattedTime: String {
        let mins = Int(startTime) / 60
        let secs = Int(startTime) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var formattedEndTime: String {
        let mins = Int(endTime) / 60
        let secs = Int(endTime) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    /// 起止时间范围，如 "[00:05→00:12]"
    var formattedTimeRange: String {
        "[\(formattedTime)→\(formattedEndTime)]"
    }
}

// MARK: - 音频片段（实时录音时根据静默切割，转写异步回填）

struct AudioChunk: Identifiable, Sendable {
    let id: String
    let meetingId: String
    var startTime: Double
    var endTime: Double
    var audioSamples: [Float]
    var text: String?
    var isTranscribing: Bool
    var speakerLabel: String?
    var isManualEdit: Bool = false
    /// 实时录音阶段提取的声纹向量，供离线分析回退复用
    var embedding: [Float]?

    var formattedTime: String {
        let mins = Int(startTime) / 60
        let secs = Int(startTime) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var formattedEndTime: String {
        let mins = Int(endTime) / 60
        let secs = Int(endTime) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var formattedDuration: String {
        let dur = Int(endTime - startTime)
        return String(format: "%ds", dur)
    }
}
