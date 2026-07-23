import Foundation
import WhisperKit

actor WhisperService {
    static let shared = WhisperService()
    
    private var pipe: WhisperKit?
    private(set) var isReady = false
    private(set) var isLoading = false

    /// 初始化并预加载模型（仅从本地磁盘加载，不访问网络）
    /// 模型必须先通过「系统配置」页面下载，否则抛出错误引导用户下载
    func initialize() async throws {
        if isReady && pipe != nil { return }
        isLoading = true
        defer { isLoading = false }
        
        let settings = SettingsManager.shared
        let modelID = SettingsManager.supportedModelID
        let basePath = settings.modelPath
        
        // 计算模型本地文件夹（与 SettingsView 下载目录结构一致）
        let primaryPath = "\(basePath)/models/argmaxinc/whisperkit-coreml/\(modelID)"
        let altPath = "\(basePath)/\(modelID)"
        
        func hasModel(at path: String) -> Bool {
            let folder = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return false }
            let marker = folder.appendingPathComponent(".download_complete")
            return FileManager.default.fileExists(atPath: marker.path)
        }
        
        let localPath: String? = hasModel(at: primaryPath) ? primaryPath : (hasModel(at: altPath) ? altPath : nil)
        
        guard let modelPath = localPath else {
            throw NSError(domain: "WhisperService", code: 404,
                userInfo: [NSLocalizedDescriptionKey: loc("model_not_downloaded_settings")])
        }
        
        let computeOptions = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU,
            prefillCompute: .cpuOnly
        )
        let config = WhisperKitConfig(modelFolder: modelPath, computeOptions: computeOptions)
        self.pipe = try await WhisperKit(config)
        self.isReady = true
        AppLog.info("Model loaded successfully: \(modelPath)")
    }
    
    /// 重置服务，以备重新载入新模型
    func reset() {
        self.pipe = nil
        self.isReady = false
    }
    
    /// 对保存的录音文件进行高精度离线转写
    func transcribe(audioURL: URL, meetingId: String, language: String = "zh", onSegments: (([TranscriptSegment]) -> Void)? = nil) async throws -> [TranscriptSegment] {
        // 强制确保模型已加载
        try await initialize()
        guard let pipe = pipe else {
            throw NSError(domain: "WhisperService", code: 1, userInfo: [NSLocalizedDescriptionKey: loc("model_load_failed")])
        }

        AppLog.info("Offline transcription started: audio=\(audioURL.lastPathComponent) lang=\(language)")

        // 设置段发现回调：转写过程中持续输出中间结果
        var callbackCount = 0
        if let onSegments = onSegments {
            pipe.segmentDiscoveryCallback = { [weak self] whisperSegments in
                guard let self = self else { return }
                callbackCount += 1
                // 每 20 次回调记录一次进度
                if callbackCount % 20 == 0 {
                    AppLog.info("WhisperKit segmentDiscovery callback #\(callbackCount): \(whisperSegments.count) new segments, lastTime=\(whisperSegments.last?.end ?? 0)s")
                }
                let mapped = whisperSegments.compactMap { seg -> TranscriptSegment? in
                    let simplifiedText = seg.text.toSimplifiedChinese()
                    guard self.isValidSpeechSegment(text: simplifiedText) else {
                        return nil
                    }
                    return TranscriptSegment(
                        id: "\(meetingId)_\(seg.id)",
                        startTime: Double(seg.start),
                        endTime: Double(seg.end),
                        text: simplifiedText,
                        speakerLabel: "?",
                        isFinal: true
                    )
                }
                onSegments(mapped)
            }
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 1,
            sampleLength: 224,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            compressionRatioThreshold: 2.0,  // large-v3 循环重复幻觉过滤
            noSpeechThreshold: 0.65           // 静音过滤敏感度
        )

        var parsedSegments: [TranscriptSegment] = []

        AppLog.info("WhisperKit transcribe() call started")
        AppLog.info("[Whisper DecodingOptions] task=\(options.task) language=\(options.language ?? "auto") temperature=\(options.temperature) tempFallbackCount=\(options.temperatureFallbackCount) tempIncrement=\(options.temperatureIncrementOnFallback) sampleLength=\(options.sampleLength) topK=\(options.topK) usePrefillPrompt=\(options.usePrefillPrompt) usePrefillCache=\(options.usePrefillCache) skipSpecialTokens=\(options.skipSpecialTokens) withoutTimestamps=\(options.withoutTimestamps) wordTimestamps=\(options.wordTimestamps) compressionRatioThreshold=\(options.compressionRatioThreshold.map { String($0) } ?? "nil") logProbThreshold=\(options.logProbThreshold.map { String($0) } ?? "nil") firstTokenLogProbThreshold=\(options.firstTokenLogProbThreshold.map { String($0) } ?? "nil") noSpeechThreshold=\(options.noSpeechThreshold.map { String($0) } ?? "nil") concurrentWorkers=\(options.concurrentWorkerCount) chunkingStrategy=\(options.chunkingStrategy.map { String(describing: $0) } ?? "nil")")
        let results = try await pipe.transcribe(audioPath: audioURL.path, decodeOptions: options)
        AppLog.info("WhisperKit transcribe() returned: \(results.first?.segments.count ?? 0) segments")

        if let result = results.first {
            for (index, segment) in result.segments.enumerated() {
                let simplifiedText = segment.text.toSimplifiedChinese()
                guard isValidSpeechSegment(text: simplifiedText) else {
                    continue
                }
                
                let parsedSegment = TranscriptSegment(
                    id: "\(meetingId)_\(segment.id)",
                    startTime: Double(segment.start),
                    endTime: Double(segment.end),
                    text: simplifiedText,
                    speakerLabel: "?", // Whisper 刚识别出文字尚未做声纹特征提取，统一设为 '?'
                    isFinal: true
                )
                parsedSegments.append(parsedSegment)
            }
        }
        
        AppLog.info("Offline transcription complete: \(parsedSegments.count) segments")
        return parsedSegments
    }
    
    /// 用于实时录音时的快速短句推理
    /// 传入音频缓冲区数组，返回转写出的连续文本
    func transcribeLive(audioArray: [Float], language: String = "zh") async throws -> String {
        guard let pipe = pipe else {
            throw NSError(domain: "WhisperService", code: 1, userInfo: [NSLocalizedDescriptionKey: loc("model_not_loaded")])
        }
        
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            skipSpecialTokens: true,
            withoutTimestamps: false
        )
        
        // 使用 WhisperKit 的纯数组转写接口
        AppLog.info("[Whisper Live DecodingOptions] task=\(options.task) language=\(options.language ?? "auto") temperature=\(options.temperature) tempFallbackCount=\(options.temperatureFallbackCount) sampleLength=\(options.sampleLength) compressionRatioThreshold=\(options.compressionRatioThreshold.map { String($0) } ?? "nil") noSpeechThreshold=\(options.noSpeechThreshold.map { String($0) } ?? "nil") skipSpecialTokens=\(options.skipSpecialTokens) withoutTimestamps=\(options.withoutTimestamps)")
        let results = try await pipe.transcribe(audioArray: audioArray, decodeOptions: options)
        
        guard let result = results.first else {
            return ""
        }
        
        // 直接使用 result.text，避免 segments 可能为空的情况
        let fullText = result.text.trimmingCharacters(in: .whitespacesAndNewlines).toSimplifiedChinese()
        guard isValidSpeechSegment(text: fullText) else {
            return ""
        }
        return fullText
    }
    
    /// 校验转写文本是否为有效语音（非空、非常见幻觉或重复循环词）
    nonisolated func isValidSpeechSegment(text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return false }
        let lower = trimmedText.lowercased()
        let hallucinations = ["字幕", "j chong", "amara.org", "感谢观看", "请不吝赐教", "不发音", "无声"]
        if hallucinations.contains(where: { lower.contains($0) }) {
            return false
        }
        if isRepetitiveHallucination(trimmedText) {
            return false
        }
        return true
    }
    
    /// 检测循环重复幻觉：分词后统计最频繁词组，超过阈值则判定为异常
    private nonisolated func isRepetitiveHallucination(_ text: String) -> Bool {
        let cleaned = text.replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
        let words = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard words.count >= 5 else { return false }
        
        let wordCounts = Dictionary(grouping: words, by: { $0 }).mapValues { $0.count }
        let maxRepeat = wordCounts.values.max() ?? 0
        // 同一词组出现 8 次以上，或占比超过 60% 即为循环幻觉
        return maxRepeat >= 8 || Double(maxRepeat) / Double(words.count) > 0.6
    }
}

extension String {
    func toSimplifiedChinese() -> String {
        let mutable = NSMutableString(string: self)
        CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
        return mutable as String
    }
}
