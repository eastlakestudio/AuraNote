import Foundation
import AVFoundation
import CSherpaOnnx

// MARK: - FunASR Service (sherpa-onnx C API wrapper)

/// 基于 sherpa-onnx 的 FunASR 语音识别服务
/// - 在线（流式）：Paraformer，低延迟实时转写
/// - 离线（整文件）：Paraformer，高精度 + 词级时间戳
/// - 标点恢复：CT-Transformer，后处理添加标点
actor FunASRService {
    static let shared = FunASRService()

    // MARK: - Online (Streaming Paraformer)

    private var onlineRecognizer: OpaquePointer?
    private var onlineStream: OpaquePointer?
    private var onlineModelDir: String = ""

    // MARK: - Offline (Paraformer)

    private var offlineRecognizer: OpaquePointer?
    private var offlineModelDir: String = ""

    // MARK: - Punctuation

    private var punctProcessor: OpaquePointer?
    private var punctModelPath: String = ""

    // MARK: - VAD (Silero)

    private var vadDetector: OpaquePointer?
    private var vadModelPath: String = ""

    // MARK: - State

    private(set) var isOnlineReady = false
    private(set) var isOfflineReady = false
    private(set) var isPunctReady = false
    private(set) var isVadReady = false
    private(set) var isLoading = false

    // MARK: - Model Path Configuration

    /// 在线 Paraformer 模型目录路径（可通过 SettingsManager 配置）
    private(set) var configuredOnlineModelDir: String = ""
    /// 在线识别器最近一次初始化时使用的热词（用于判断是否需要重建）
    private var configuredOnlineHotwords: String = ""

    /// 离线 Paraformer 模型目录路径
    private(set) var configuredOfflineModelDir: String = ""
    /// 离线识别器最近一次初始化时使用的热词（用于判断是否需要重建）
    private var configuredOfflineHotwords: String = ""

    /// 标点模型文件路径
    private(set) var configuredPunctModelPath: String = ""

    /// VAD 模型文件路径（silero_vad.onnx）
    private(set) var configuredVadModelPath: String = ""

    func updateModelPaths(online: String, offline: String, punct: String, vad: String) {
        self.configuredOnlineModelDir = online
        self.configuredOfflineModelDir = offline
        self.configuredPunctModelPath = punct
        self.configuredVadModelPath = vad
    }

    // MARK: - Initialize Online (Streaming Paraformer)

    /// 初始化在线流式 Paraformer 模型
    /// - Parameters:
    ///   - modelDir: 模型目录，包含 encoder.int8.onnx、decoder.int8.onnx、tokens.txt
    ///   - hotwords: 热词文本，通过 config.hotwords_buf 注入（Paraformer 不支持 per-stream 热词）
    func initializeOnline(modelDir: String? = nil, hotwords: String = "") throws {
        let dir = modelDir ?? configuredOnlineModelDir
        guard !dir.isEmpty else {
            throw FunASRError.modelNotFound("在线模型路径未配置")
        }
        if isOnlineReady && onlineRecognizer != nil && dir == configuredOnlineModelDir && hotwords == configuredOnlineHotwords { return }

        isLoading = true
        defer { isLoading = false }

        destroyOnline()

        let encoderPath = dir + "/encoder.int8.onnx"
        let decoderPath = dir + "/decoder.int8.onnx"
        let tokensPath = dir + "/tokens.txt"

        guard FileManager.default.fileExists(atPath: encoderPath),
              FileManager.default.fileExists(atPath: decoderPath),
              FileManager.default.fileExists(atPath: tokensPath) else {
            throw FunASRError.modelNotFound("在线模型文件不完整: \(dir)")
        }

        try encoderPath.withCString { encoderCStr in
            try decoderPath.withCString { decoderCStr in
                try tokensPath.withCString { tokensCStr in
                    try "cpu".withCString { providerCStr in
                        try "greedy_search".withCString { methodCStr in
                            var config = SherpaOnnxOnlineRecognizerConfig()
                            memset(&config, 0, MemoryLayout<SherpaOnnxOnlineRecognizerConfig>.size)

                            config.feat_config.sample_rate = 16000
                            config.feat_config.feature_dim = 80

                            config.model_config.paraformer.encoder = encoderCStr
                            config.model_config.paraformer.decoder = decoderCStr
                            config.model_config.tokens = tokensCStr
                            config.model_config.num_threads = 2
                            config.model_config.provider = providerCStr
                            config.model_config.debug = 0

                            config.decoding_method = methodCStr
                            config.enable_endpoint = 0
                            config.hotwords_score = SettingsManager.shared.hotwordsScore

                            // 通过 config 级 hotwords_buf 注入热词（Paraformer 支持此方式）
                            let hw = hotwords.trimmingCharacters(in: .whitespaces)
                            if !hw.isEmpty {
                                hw.withCString { hwCStr in
                                    config.hotwords_buf = hwCStr
                                    config.hotwords_buf_size = Int32(strlen(hwCStr))
                                }
                            }

                            guard let rec = SherpaOnnxCreateOnlineRecognizer(&config) else {
                                throw FunASRError.initializationFailed("创建在线 Paraformer 识别器失败")
                            }
                            self.onlineRecognizer = rec
                            self.configuredOnlineModelDir = dir
                            self.configuredOnlineHotwords = hotwords
                            self.isOnlineReady = true
                            AppLog.info("[FunASR] Online Paraformer initialized: \(dir), hotwords=\(hw.isEmpty ? "(none)" : "\(hw.count) chars")")
                        }
                    }
                }
            }
        }
    }

    /// 创建或重建在线流（每次新录音开始时调用）
    /// 注意：Paraformer 不支持 SherpaOnnxCreateOnlineStreamWithHotwords（仅 Transducer 支持），
    /// 热词通过 recognizer config 的 hotwords_score 参数控制，此处使用普通 stream。
    func createOnlineStream(hotwords: String = "") throws {
        guard let rec = onlineRecognizer else {
            throw FunASRError.notInitialized("在线识别器未初始化")
        }
        destroyOnlineStream()

        let stream = SherpaOnnxCreateOnlineStream(rec)

        guard let stream = stream else {
            throw FunASRError.initializationFailed("创建在线 Paraformer stream 失败")
        }
        self.onlineStream = stream
    }

    // MARK: - Online Streaming Methods

    /// 喂入音频样本到流式识别器
    /// - Parameters:
    ///   - samples: 单声道 float32 PCM，归一化到 [-1, 1]
    ///   - sampleRate: 采样率（默认 16000，sherpa-onnx 内部会自动重采样）
    func acceptWaveform(samples: [Float], sampleRate: Int32 = 16000) {
        guard let stream = onlineStream else { return }
        var mutableSamples = samples
        SherpaOnnxOnlineStreamAcceptWaveform(stream, sampleRate, &mutableSamples, Int32(samples.count))
    }

    /// 检查是否有足够的帧可以解码
    func isStreamReady() -> Bool {
        guard let rec = onlineRecognizer, let stream = onlineStream else { return false }
        return SherpaOnnxIsOnlineStreamReady(rec, stream) == 1
    }

    /// 解码一步，返回当前累积的识别文本
    /// - Returns: 累积的识别文本，若无结果则返回 nil
    func decodeStream() -> String? {
        guard let rec = onlineRecognizer, let stream = onlineStream else { return nil }

        while SherpaOnnxIsOnlineStreamReady(rec, stream) != 0 {
            SherpaOnnxDecodeOnlineStream(rec, stream)
        }

        guard let result = SherpaOnnxGetOnlineStreamResult(rec, stream) else { return nil }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }

        guard let text = result.pointee.text else { return nil }
        return String(cString: text)
    }

    /// 解码并返回增量文本（相比上次结果新增的部分）
    private var lastDecodedText: String = ""

    func decodeStreamIncremental() -> String? {
        guard let fullText = decodeStream() else { return nil }
        let trimmed = fullText.trimmingCharacters(in: .whitespaces)

        // 计算增量
        if trimmed.hasPrefix(lastDecodedText) {
            let incremental = String(trimmed.dropFirst(lastDecodedText.count)).trimmingCharacters(in: .whitespaces)
            lastDecodedText = trimmed
            return incremental.isEmpty ? nil : incremental
        } else {
            // 文本回退或重置，全量返回
            lastDecodedText = trimmed
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// 标记输入结束（录音停止时调用）
    func inputFinished() {
        guard let stream = onlineStream else { return }
        SherpaOnnxOnlineStreamInputFinished(stream)
    }

    /// 重置在线流状态（用于下一段录音）
    func resetOnlineStream() {
        lastDecodedText = ""
        guard let rec = onlineRecognizer, let stream = onlineStream else { return }
        SherpaOnnxOnlineStreamReset(rec, stream)
    }

    // MARK: - Initialize Offline (Paraformer)

    /// 初始化离线 Paraformer 模型（带词级时间戳）
    /// - Parameters:
    ///   - modelDir: 模型目录，包含 model.int8.onnx、tokens.txt
    ///   - hotwords: 热词文本，通过 config.hotwords_file 注入（Paraformer 离线仅支持文件方式）
    func initializeOffline(modelDir: String? = nil, hotwords: String = "") throws {
        let dir = modelDir ?? configuredOfflineModelDir
        guard !dir.isEmpty else {
            throw FunASRError.modelNotFound("离线模型路径未配置")
        }
        if isOfflineReady && offlineRecognizer != nil && dir == configuredOfflineModelDir && hotwords == configuredOfflineHotwords { return }

        isLoading = true
        defer { isLoading = false }

        destroyOffline()

        let modelPath = dir + "/model.int8.onnx"
        let tokensPath = dir + "/tokens.txt"

        guard FileManager.default.fileExists(atPath: modelPath),
              FileManager.default.fileExists(atPath: tokensPath) else {
            throw FunASRError.modelNotFound("离线 Paraformer 模型文件不完整: \(dir)")
        }

        // 离线 Paraformer 仅支持 hotwords_file，不支持 hotwords_buf，需写入临时文件
        let hw = hotwords.trimmingCharacters(in: .whitespaces)
        var hotwordsFilePath: String? = nil
        if !hw.isEmpty {
            let tmpDir = NSTemporaryDirectory()
            let tmpPath = tmpDir + "auranote_hotwords_\(UUID().uuidString).txt"
            try hw.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            hotwordsFilePath = tmpPath
        }
        defer {
            if let p = hotwordsFilePath { try? FileManager.default.removeItem(atPath: p) }
        }

        try modelPath.withCString { modelCStr in
            try tokensPath.withCString { tokensCStr in
                try "cpu".withCString { providerCStr in
                    try "greedy_search".withCString { methodCStr in
                        var config = SherpaOnnxOfflineRecognizerConfig()
                        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineRecognizerConfig>.size)

                        config.feat_config.sample_rate = 16000
                        config.feat_config.feature_dim = 80

                        config.model_config.paraformer.model = modelCStr
                        config.model_config.tokens = tokensCStr
                        config.model_config.num_threads = 2
                        config.model_config.provider = providerCStr
                        config.model_config.debug = 0

                        config.decoding_method = methodCStr
                        config.hotwords_score = SettingsManager.shared.hotwordsScore

                        // 离线 Paraformer 仅支持 hotwords_file（无 hotwords_buf）
                        if let hwPath = hotwordsFilePath {
                            hwPath.withCString { hwPathCStr in
                                config.hotwords_file = hwPathCStr
                            }
                        }

                        guard let rec = SherpaOnnxCreateOfflineRecognizer(&config) else {
                            throw FunASRError.initializationFailed("创建离线 Paraformer 识别器失败")
                        }
                        self.offlineRecognizer = rec
                        self.configuredOfflineModelDir = dir
                        self.configuredOfflineHotwords = hotwords
                        self.isOfflineReady = true
                        AppLog.info("[FunASR] Offline Paraformer initialized: \(dir), hotwords=\(hw.isEmpty ? "(none)" : "\(hw.count) chars")")
                    }
                }
            }
        }
    }

    // MARK: - Offline Transcription

    /// 离线整文件转写（Paraformer），返回带时间戳的 TranscriptSegment 数组
    /// - Parameters:
    ///   - audioURL: 音频文件 URL
    ///   - meetingId: 会议 ID，用于生成 segment ID
    ///   - language: 语言提示（Paraformer 支持 zh/en 双语）
    /// - Returns: 转写片段数组
    func transcribe(audioURL: URL, meetingId: String, language: String = "auto", hotwords: String = "") throws -> [TranscriptSegment] {
        guard let rec = offlineRecognizer else {
            throw FunASRError.notInitialized("离线识别器未初始化")
        }

        // 读取 WAV 文件为 PCM 样本
        let (samples, sampleRate) = try loadWAVSamples(from: audioURL)

        // 创建离线流（Paraformer 不支持 WithHotwords，仅 Transducer 支持）
        guard let stream = SherpaOnnxCreateOfflineStream(rec) else {
            throw FunASRError.initializationFailed("创建离线 stream 失败")
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        // 喂入完整音频
        var mutableSamples = samples
        SherpaOnnxAcceptWaveformOffline(stream, sampleRate, &mutableSamples, Int32(samples.count))

        // 解码
        SherpaOnnxDecodeOfflineStream(rec, stream)

        // 获取结果
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw FunASRError.processingFailed("离线解码未返回结果")
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }

        let r = result.pointee

        // Paraformer 的 token 级结果（通过 tokens_arr + timestamps 获取精确时间戳）
        var segments: [TranscriptSegment] = []

        // 尝试使用分段结果（若模型支持）
        if r.segment_count > 0,
           let segTexts = r.segment_texts_arr,
           let segStarts = r.segment_timestamps,
           let segDurs = r.segment_durations {

            for i in 0..<Int(r.segment_count) {
                guard let segText = segTexts[i] else { continue }
                let text = String(cString: segText).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let startTime = Double(segStarts[i])
                let duration = Double(segDurs[i])

                segments.append(TranscriptSegment(
                    id: "\(meetingId)_paraformer_\(i)",
                    startTime: startTime,
                    endTime: startTime + duration,
                    text: text.toSimplifiedChinese(),
                    speakerLabel: "?",
                    isFinal: true
                ))
            }
        }

        // 若没有分段结果，使用完整文本（单段回退）
        if segments.isEmpty, let fullText = r.text {
            let text = String(cString: fullText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let duration = Double(samples.count) / Double(sampleRate)
                segments.append(TranscriptSegment(
                    id: "\(meetingId)_paraformer_0",
                    startTime: 0,
                    endTime: duration,
                    text: text.toSimplifiedChinese(),
                    speakerLabel: "?",
                    isFinal: true
                ))
            }
        }

        AppLog.info("[FunASR] Offline transcription complete: \(segments.count) segments")
        return segments
    }

    // MARK: - VAD-Segment Based Transcription (spk_mode="vad_segment" 策略)

    /// 基于 VAD 分段的逐段转写：每个 VAD 段独立送入 Paraformer，一段 = 一句（或多句）= 一人
    ///
    /// **核心思路（对应 FunASR 官方 spk_mode="vad_segment"）**：
    /// 1. VAD 段是自然的说话人边界——停顿 = 句边界 ≈ 说话人切换点
    /// 2. 每段独立 ASR，输出天然不与跨说话人片段混淆
    /// 3. 声纹分离在同样的 VAD 段上运行，标签通过时间重叠 1:1 映射
    ///
    /// **与旧版 transcribeProgressive 的区别**：
    /// - 旧版：30s 滑动窗口 → 后处理切句 → 交叉对齐（复杂、重复文本、精度低）
    /// - 新版：VAD 段 → 逐段 ASR → 时间对齐（简洁、无重复、天然单人）
    ///
    /// - Parameters:
    ///   - samples: 完整音频采样（16kHz float32）
    ///   - sampleRate: 采样率
    ///   - vadSegments: VAD 切分的语音段边界数组
    ///   - meetingId: 会议 ID
    ///   - onSegment: 每识别出一个句子时回调
    /// - Returns: 总句子数
    func transcribeVadSegments(
        samples: [Float],
        sampleRate: Int32,
        vadSegments: [(start: Double, end: Double)],
        meetingId: String,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void
    ) async throws -> Int {
        guard let rec = offlineRecognizer else {
            throw FunASRError.notInitialized("离线识别器未初始化")
        }

        let totalDuration = Double(samples.count) / Double(sampleRate)
        let contextSec: Double = 0.3  // 前后各扩 300ms 上下文，防止子词截断

        var totalSegments = 0
        AppLog.info("[FunASR] VAD-segment ASR: \(vadSegments.count) VAD segments, \(String(format: "%.1f", totalDuration))s audio")

        for (idx, vadSeg) in vadSegments.enumerated() {
            try Task.checkCancellation()

            let segDuration = vadSeg.end - vadSeg.start
            guard segDuration >= 0.3 else { continue }

            // 前后扩展上下文（不改变输出段时间戳，仅改善 ASR 质量）
            let ctxStart = max(0, vadSeg.start - contextSec)
            let ctxEnd = min(totalDuration, vadSeg.end + contextSec)
            let startSample = Int(ctxStart * Double(sampleRate))
            let endSample = min(Int(ctxEnd * Double(sampleRate)), samples.count)
            guard startSample < endSample else { continue }

            let slice = Array(samples[startSample..<endSample])

            guard let stream = SherpaOnnxCreateOfflineStream(rec) else { continue }
            var mutableSlice = slice
            SherpaOnnxAcceptWaveformOffline(stream, sampleRate, &mutableSlice, Int32(slice.count))
            SherpaOnnxDecodeOfflineStream(rec, stream)

            guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
                SherpaOnnxDestroyOfflineStream(stream)
                continue
            }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
            SherpaOnnxDestroyOfflineStream(stream)

            let r = result.pointee

            // 获取原始文本
            let rawText: String
            if r.count > 0, let tokensArr = r.tokens_arr {
                var chars: [Character] = []
                for ti in 0..<Int(r.count) {
                    guard let tokenStr = tokensArr[ti] else { continue }
                    var token = String(cString: tokenStr)
                    if token == "@" { continue }
                    let hasBoundary = token.hasPrefix("\u{2581}")
                    if hasBoundary { token = String(token.dropFirst()) }
                    let isContinuation = token.hasSuffix("@@")
                    if isContinuation { token = String(token.dropLast(2)) }
                    guard !token.isEmpty else { continue }
                    if hasBoundary && !chars.isEmpty { chars.append(" ") }
                    for ch in token { chars.append(ch) }
                }
                rawText = String(chars).toSimplifiedChinese()
            } else if let fullText = r.text {
                rawText = String(cString: fullText).toSimplifiedChinese()
            } else {
                continue
            }

            let cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            // 标点恢复
            let punctuated = isPunctReady ? addPunctuation(cleaned) : cleaned

            // 短段（< 2s）直接作为一个句子输出；长段按标点分句
            if segDuration < 2.0 {
                let trimmed = punctuated
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingPunctuation()
                guard !trimmed.isEmpty else { continue }
                onSegment(TranscriptSegment(
                    id: "\(meetingId)_vad_\(idx)",
                    startTime: vadSeg.start,
                    endTime: vadSeg.end,
                    text: trimmed,
                    speakerLabel: "?",
                    isFinal: true
                ))
                totalSegments += 1
            } else {
                let sentences = splitBySentences(punctuated)
                let nonEmpty = sentences.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingPunctuation()
                }.filter { !$0.isEmpty }

                if nonEmpty.isEmpty {
                    let trimmed = punctuated
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingPunctuation()
                    guard !trimmed.isEmpty else { continue }
                    onSegment(TranscriptSegment(
                        id: "\(meetingId)_vad_\(idx)",
                        startTime: vadSeg.start,
                        endTime: vadSeg.end,
                        text: trimmed,
                        speakerLabel: "?",
                        isFinal: true
                    ))
                    totalSegments += 1
                } else {
                    for (j, trimmed) in nonEmpty.enumerated() {
                        let ratio0 = Double(j) / Double(nonEmpty.count)
                        let ratio1 = Double(j + 1) / Double(nonEmpty.count)
                        let segStart = vadSeg.start + ratio0 * segDuration
                        let segEnd = vadSeg.start + ratio1 * segDuration
                        onSegment(TranscriptSegment(
                            id: "\(meetingId)_vad_\(idx)_\(j)",
                            startTime: max(segStart, 0),
                            endTime: max(segEnd, segStart + 0.1),
                            text: trimmed,
                            speakerLabel: "?",
                            isFinal: true
                        ))
                        totalSegments += 1
                    }
                }
            }
        }

        AppLog.info("[FunASR] VAD-segment ASR complete: \(totalSegments) sentences from \(vadSegments.count) VAD segments")
        return totalSegments
    }

    /// 合并相邻 VAD 段：间距 < maxGap 的段合成一段，防止 ASR 在句中短暂停顿时拦腰切断
    /// 时间复杂度 O(n log n)，原地排序后单次扫描
    nonisolated static func mergeAdjacentVadSegments(
        _ segments: [(start: Double, end: Double)],
        maxGap: Double = 0.3,
        maxDuration: Double = 30.0
    ) -> [(start: Double, end: Double)] {
        guard segments.count > 1 else { return segments }
        let sorted = segments.sorted { $0.start < $1.start }
        var merged: [(start: Double, end: Double)] = []
        for seg in sorted {
            if let last = merged.last, seg.start - last.end <= maxGap {
                let candidateEnd = max(last.end, seg.end)
                if candidateEnd - last.start <= maxDuration {
                    merged[merged.count - 1] = (last.start, candidateEnd)
                } else {
                    merged.append(seg)
                }
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    // MARK: - VAD 累积式离线转写

    /// VAD 累积式转写：Silero VAD 检测语音段 → 合并相邻段(≤1.5s) → 累积至 ~30s → Paraformer 转写
    ///
    /// **与 transcribeProgressive（固定30s窗口）的区别**：
    /// - VAD 保证切分点落在自然语音停顿处，不会在句中拦腰切断
    /// - 相邻段合并（≤1.5s 间隔）防止句中短暂停顿被误切
    /// - 累积到 ~30s 语音后再送 ASR，兼顾上下文完整性和 chunk 大小控制
    func transcribeVadAccumulated(
        audioURL: URL,
        meetingId: String,
        hotwords: String = "",
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void
    ) async throws -> Int {
        guard let rec = offlineRecognizer else {
            throw FunASRError.notInitialized("离线识别器未初始化")
        }
        guard isVadReady, let vad = vadDetector else {
            throw FunASRError.notInitialized("VAD 检测器未初始化，请先调用 initializeVAD()")
        }

        let (samples, sampleRate) = try loadWAVSamples(from: audioURL)
        let totalDuration = Double(samples.count) / Double(sampleRate)
        AppLog.info("[FunASR] VAD-Accum: loaded \(samples.count) samples, \(String(format: "%.1f", totalDuration))s")

        // === 第1步：Silero VAD 逐窗检测语音段 ===
        SherpaOnnxVoiceActivityDetectorReset(vad)
        let windowSize: Int32 = 512
        var rawSegments: [(start: Double, end: Double)] = []

        for i in stride(from: 0, to: samples.count, by: Int(windowSize)) {
            let end = min(i + Int(windowSize), samples.count)
            var chunk = Array(samples[i..<end])
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, &chunk, Int32(chunk.count))

            while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
                guard let seg = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
                let s = seg.pointee
                rawSegments.append((start: Double(s.start) / Double(sampleRate),
                                    end: Double(s.start + s.n) / Double(sampleRate)))
                SherpaOnnxDestroySpeechSegment(seg)
                SherpaOnnxVoiceActivityDetectorPop(vad)
            }
        }
        SherpaOnnxVoiceActivityDetectorFlush(vad)
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            guard let seg = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
            let s = seg.pointee
            rawSegments.append((start: Double(s.start) / Double(sampleRate),
                                end: Double(s.start + s.n) / Double(sampleRate)))
            SherpaOnnxDestroySpeechSegment(seg)
            SherpaOnnxVoiceActivityDetectorPop(vad)
        }
        SherpaOnnxVoiceActivityDetectorReset(vad)

        guard !rawSegments.isEmpty else {
            AppLog.warn("[FunASR] VAD detected no speech segments")
            return 0
        }
        AppLog.info("[FunASR] VAD raw: \(rawSegments.count) segments")

        // === 第2步：合并相邻段（使用较小的 gap 让 VAD 紧紧包裹语音，提升等比例时间戳的精度）===
        let mergedVad = FunASRService.mergeAdjacentVadSegments(rawSegments, maxGap: 0.5, maxDuration: 15.0)
        AppLog.info("[FunASR] VAD merged: \(mergedVad.count) segments (gap ≤ 0.5s, maxDuration ≤ 15.0s)")

        // === 第3步：直接使用 mergedVad 作为句子，逐块转写 ===
        // 完全参考 Python FunASR 的思路：每个 VAD 段作为一个物理句子，直接绑定其 start 和 end 时间戳。
        var allSegments: [TranscriptSegment] = []
        let contextSec: Double = 0.3
        
        for (chunkIdx, chunk) in mergedVad.enumerated() {
            try Task.checkCancellation()
            let chunkDur = chunk.end - chunk.start
            guard chunkDur >= 0.2 else { continue }

            let ctxStart = max(0, chunk.start - contextSec)
            let ctxEnd = min(totalDuration, chunk.end + contextSec)
            let startSample = Int(ctxStart * Double(sampleRate))
            let endSample = min(Int(ctxEnd * Double(sampleRate)), samples.count)
            guard startSample < endSample else { continue }

            let slice = Array(samples[startSample..<endSample])

            // Paraformer 不支持 WithHotwords，始终使用普通 stream
            guard let stream = SherpaOnnxCreateOfflineStream(rec) else { continue }
            var mutableSlice = slice
            SherpaOnnxAcceptWaveformOffline(stream, sampleRate, &mutableSlice, Int32(slice.count))
            SherpaOnnxDecodeOfflineStream(rec, stream)

            guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
                SherpaOnnxDestroyOfflineStream(stream)
                continue
            }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
            SherpaOnnxDestroyOfflineStream(stream)

            let r = result.pointee
            if let fullText = r.text {
                let textStr = String(cString: fullText).toSimplifiedChinese().trimmingCharacters(in: .whitespacesAndNewlines)
                if !textStr.isEmpty {
                    // 组装结构体：直接将 VAD 段作为一句话，赋予完整的起止时间
                    let punctuated = isPunctReady ? addPunctuation(textStr) : textStr
                    
                    let startMs = Int(chunk.start * 1000)
                    let endMs = Int(chunk.end * 1000)
                    AppLog.info("[FunASR-DEBUG] Sentence \(chunkIdx) info: start=\(startMs)ms, end=\(endMs)ms, text='\(punctuated)'")
                    
                    allSegments.append(TranscriptSegment(
                        id: "\(meetingId)_vad_\(chunkIdx)",
                        startTime: chunk.start,
                        endTime: chunk.end,
                        text: punctuated,
                        speakerLabel: "?",
                        isFinal: true
                    ))
                }
            }
        }

        let total = allSegments.count
        AppLog.info("[FunASR] VAD-Accum final: \(total) sentences generated directly from VAD")
        for seg in allSegments { onSegment(seg) }
        return total
    }
    
    /// 按照声纹分离后的片段逐个转写（直接使用预加载的音频样本，避免重复读盘）
    /// - Parameters:
    ///   - samples: 音频浮点样本数组 (16kHz)
    ///   - sampleRate: 采样率，默认 16000
    ///   - diarSegments: Diarization 输出的带说话人标签的纯净片段
    ///   - meetingId: 会议ID
    ///   - onSegment: 转写完一个片段后的回调
    /// - Returns: 总生成的句子数
    func transcribeDiarizedSegments(
        samples: [Float],
        sampleRate: Int = 16000,
        diarSegments: [DiarizedSegment],
        meetingId: String,
        hotwords: String = "",
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void
    ) async throws -> Int {
        guard let rec = offlineRecognizer else { return 0 }
        
        let totalDuration = Double(samples.count) / Double(sampleRate)
        let contextSec: Double = 0.0  // 不使用上下文扩展，防止重复字词
        var allSegments: [TranscriptSegment] = []
        
        for seg in diarSegments {
            try Task.checkCancellation()
            
            let ctxStart = max(0, seg.startTime - contextSec)
            let ctxEnd = min(totalDuration, seg.endTime + contextSec)
            let startSample = Int(ctxStart * Double(sampleRate))
            let endSample = min(Int(ctxEnd * Double(sampleRate)), samples.count)
            guard startSample < endSample else { continue }
            
            let slice = Array(samples[startSample..<endSample])
            
            // Paraformer 不支持 WithHotwords，始终使用普通 stream
            guard let stream = SherpaOnnxCreateOfflineStream(rec) else { continue }
            var mutableSlice = slice
            SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), &mutableSlice, Int32(slice.count))
            SherpaOnnxDecodeOfflineStream(rec, stream)
            
            guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
                SherpaOnnxDestroyOfflineStream(stream)
                continue
            }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
            SherpaOnnxDestroyOfflineStream(stream)
            
            let r = result.pointee
            if let fullText = r.text {
                let textStr = String(cString: fullText).toSimplifiedChinese().trimmingCharacters(in: .whitespacesAndNewlines)
                if !textStr.isEmpty {
                    let punctuated = isPunctReady ? addPunctuation(textStr) : textStr
                    
                    let startMs = Int(seg.startTime * 1000)
                    let endMs = Int(seg.endTime * 1000)
                    AppLog.info("[FunASR-DEBUG] DiarSegment [\(seg.speakerId)]: start=\(startMs)ms, end=\(endMs)ms, text='\(punctuated)'")
                    
                    let ts = TranscriptSegment(
                        id: "\(meetingId)_diar_\(UUID().uuidString)",
                        startTime: seg.startTime,
                        endTime: seg.endTime,
                        text: punctuated,
                        speakerLabel: seg.speakerId,
                        isFinal: true
                    )
                    allSegments.append(ts)
                    onSegment(ts)
                }
            }
        }
        
        AppLog.info("[FunASR] transcribeDiarizedSegments final: \(allSegments.count) sentences generated from \(diarSegments.count) diar segments")
        return allSegments.count
    }

    /// 按照声纹分离后的片段逐个转写（URL 版本）

    /// - Parameters:
    ///   - audioURL: 音频文件
    ///   - diarSegments: Diarization 输出的带说话人标签的纯净片段
    ///   - meetingId: 会议ID
    ///   - hotwords: 热词
    ///   - onSegment: 转写完一个片段后的回调
    /// - Returns: 总生成的句子数
    func transcribeDiarizedSegments(
        audioURL: URL,
        diarSegments: [DiarizedSegment],
        meetingId: String,
        hotwords: String = "",
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void
    ) async throws -> Int {
        let (samples, sampleRate) = try loadWAVSamples(from: audioURL)
        guard let rec = offlineRecognizer else { return 0 }
        
        let totalDuration = Double(samples.count) / Double(sampleRate)
        let contextSec: Double = 0.0  // 不使用上下文扩展，因为 diarization 已经严格按说话人切分了，扩展会导致相邻说话人的语音重叠，从而产生重复的字词
        var allSegments: [TranscriptSegment] = []
        
        for seg in diarSegments {
            try Task.checkCancellation()
            
            let ctxStart = max(0, seg.startTime - contextSec)
            let ctxEnd = min(totalDuration, seg.endTime + contextSec)
            let startSample = Int(ctxStart * Double(sampleRate))
            let endSample = min(Int(ctxEnd * Double(sampleRate)), samples.count)
            guard startSample < endSample else { continue }
            
            let slice = Array(samples[startSample..<endSample])
            
            // Paraformer 不支持 WithHotwords，始终使用普通 stream
            guard let stream = SherpaOnnxCreateOfflineStream(rec) else { continue }
            var mutableSlice = slice
            SherpaOnnxAcceptWaveformOffline(stream, sampleRate, &mutableSlice, Int32(slice.count))
            SherpaOnnxDecodeOfflineStream(rec, stream)
            
            guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
                SherpaOnnxDestroyOfflineStream(stream)
                continue
            }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
            SherpaOnnxDestroyOfflineStream(stream)
            
            let r = result.pointee
            if let fullText = r.text {
                let textStr = String(cString: fullText).toSimplifiedChinese().trimmingCharacters(in: .whitespacesAndNewlines)
                if !textStr.isEmpty {
                    AppLog.info("[FunASR-DEBUG] Before punct (isPunctReady=\(isPunctReady)): '\(textStr)'")
                    let punctuated = isPunctReady ? addPunctuation(textStr) : textStr
                    AppLog.info("[FunASR-DEBUG] After punct: '\(punctuated)'")
                    
                    let startMs = Int(seg.startTime * 1000)
                    let endMs = Int(seg.endTime * 1000)
                    AppLog.info("[FunASR-DEBUG] DiarSegment [\(seg.speakerId)]: start=\(startMs)ms, end=\(endMs)ms, text='\(punctuated)'")
                    
                    let ts = TranscriptSegment(
                        id: "\(meetingId)_diar_\(UUID().uuidString)",
                        startTime: seg.startTime,
                        endTime: seg.endTime,
                        text: punctuated,
                        speakerLabel: seg.speakerId,
                        isFinal: true
                    )
                    allSegments.append(ts)
                    onSegment(ts)
                }
            }
        }
        
        AppLog.info("[FunASR] transcribeDiarizedSegments final: \(allSegments.count) sentences generated from \(diarSegments.count) diar segments")
        return allSegments.count
    }

    // MARK: - Helper Methods

    /// 渐进式离线转写：30 秒滑动窗口 → 逐段 Paraformer 转写 → token 级时间戳分句
    ///
    /// **分段策略**：
    /// 1. 每 30 秒一个窗口，2 秒前后重叠防止截断句子
    /// 2. Paraformer 输出 token 级时间戳，精确到毫秒
    /// 3. 标点恢复后按句末标点分句，通过字符→token 映射获取精确起止时间
    /// 4. 相邻窗口文本相似度去重
    ///
    /// - Parameters:
    ///   - audioURL: 音频文件 URL
    ///   - meetingId: 会议 ID
    ///   - language: 语言提示
    ///   - onSegment: 每识别出一个句子时回调
    /// - Returns: 总句子数
    func transcribeProgressive(
        audioURL: URL,
        meetingId: String,
        language: String = "auto",
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void
    ) async throws -> Int {
        guard let rec = offlineRecognizer else {
            throw FunASRError.notInitialized("离线识别器未初始化")
        }

        let (samples, sampleRate) = try loadWAVSamples(from: audioURL)
        let totalDuration = Double(samples.count) / Double(sampleRate)
        let totalSamples = samples.count
        AppLog.info("[FunASR] Progressive: loaded \(totalSamples) samples @ \(sampleRate)Hz, \(String(format: "%.1f", totalDuration))s")

        // 30 秒分段渐进式转写：每段立即输出，首段 1~2 秒即见结果
        // 2 秒前后重叠，防止窗口边界劈断句子；重叠区内句子跳过（去重）
        let chunkSeconds: Double = 30.0
        let chunkSamples = Int(chunkSeconds * Double(sampleRate))
        let overlapSeconds: Double = 2.0
        let overlapSamples = Int(overlapSeconds * Double(sampleRate))

        var totalSegments = 0
        var chunkIdx = 0
        var chunkStart = 0
        var allSegments: [TranscriptSegment] = []  // 收集所有窗口的句子，最后合并去重

        while chunkStart < totalSamples {
            try Task.checkCancellation()
            let chunkEnd = min(chunkStart + chunkSamples, totalSamples)
            let slice = Array(samples[chunkStart..<chunkEnd])
            let timeOffset = Double(chunkStart) / Double(sampleRate)
            let chunkEndTime = Double(chunkEnd) / Double(sampleRate)
            let chunkDur = Double(slice.count) / Double(sampleRate)

            guard let stream = SherpaOnnxCreateOfflineStream(rec) else {
                throw FunASRError.initializationFailed("创建离线 stream 失败")
            }
            var mutableSlice = slice
            SherpaOnnxAcceptWaveformOffline(stream, sampleRate, &mutableSlice, Int32(slice.count))
            SherpaOnnxDecodeOfflineStream(rec, stream)

            guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
                SherpaOnnxDestroyOfflineStream(stream)
                if chunkEnd >= totalSamples { break }
                chunkStart = chunkEnd - overlapSamples
                chunkIdx += 1
                continue
            }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
            SherpaOnnxDestroyOfflineStream(stream)

            let r = result.pointee

            // === Paraformer token 级时间戳 ===
            // tokens_arr 和 timestamps 并行数组，token i 的开始时间为 timestamps[i]
            let hasTokens = r.count > 0 && r.tokens_arr != nil && r.timestamps != nil
            let hasText = r.text != nil
            AppLog.info("[FunASR] Window \(chunkIdx): count=\(r.count) hasTokens=\(hasTokens) hasText=\(hasText)")

            // 优先使用 token 级时间戳；回退到 r.text（无时间戳的单段结果）
            if hasTokens, let tokensArr = r.tokens_arr, let tsPtr = r.timestamps {

            // 构建 raw text + 字符→token 索引映射
            // SentencePiece 解码：
            //   ▁ 前缀 = 词边界（英文空格），@@ 后缀 = 连续标记
            //   中文 token 无标记，直接拼接即可
            var rawChars: [Character] = []
            var charToTokenIdx: [Int] = []
            for ti in 0..<Int(r.count) {
                guard let tokenStr = tokensArr[ti] else { continue }
                var token = String(cString: tokenStr)

                // 跳过纯 @ token（byte-fallback 残留）
                if token == "@" { continue }

                // ▁ 前缀 = SentencePiece 词边界空格
                let hasBoundary = token.hasPrefix("\u{2581}")
                if hasBoundary { token = String(token.dropFirst()) }

                // @@ 后缀 = 连续标记（与前一 token 合并，不加空格）
                let isContinuation = token.hasSuffix("@@")
                if isContinuation { token = String(token.dropLast(2)) }

                guard !token.isEmpty else { continue }

                for ch in token {
                    rawChars.append(ch)
                    charToTokenIdx.append(ti)
                }
            }
            let rawText = String(rawChars).toSimplifiedChinese()
            guard !rawText.isEmpty else {
                if chunkEnd >= totalSamples { break }
                chunkStart = chunkEnd - overlapSamples
                chunkIdx += 1
                continue
            }

            // 标点恢复 + 分句
            let punctuated = isPunctReady ? addPunctuation(rawText) : rawText
            let sentences = splitBySentences(punctuated)

            // ---- token 时间戳 → 句边界 ----
            for (j, sentence) in sentences.enumerated() {
                let trimmed = sentence
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingPunctuation()
                guard !trimmed.isEmpty else { continue }

                // 先计算 tokenTimestamps（内部已对标点与 rawText 做剥离映射）
                let tokenTs = buildTokenTimestamps(
                    text: trimmed, rawText: rawText,
                    charToTokenIdx: charToTokenIdx, tsPtr: tsPtr, timeOffset: timeOffset)

                // 句子起止时间：优先用 tokenTimestamps
                let segStart: Double
                let segEnd: Double
                var lastTokenDur: Double = 0.3
                if let ts = tokenTs, !ts.isEmpty {
                    segStart = ts.first!
                    let punctSet: Set<Character> = ["，", "。", "！", "？", "；", "：", "、", ",", ".", "!", "?"]
                    let stripped = String(trimmed.filter { !punctSet.contains($0) })
                    if !stripped.isEmpty,
                       let rawRange = rawText.range(of: stripped) {
                        let eIdx = rawText.distance(from: rawText.startIndex, to: rawRange.upperBound) - 1
                        if eIdx < charToTokenIdx.count {
                            lastTokenDur = r.durations != nil ? Double(r.durations![charToTokenIdx[eIdx]]) : 0.3
                        }
                    }
                    segEnd = ts.last! + lastTokenDur
                } else if let rawRange = rawText.range(of: trimmed) {
                    let sIdx = rawText.distance(from: rawText.startIndex, to: rawRange.lowerBound)
                    let eIdx = rawText.distance(from: rawText.startIndex, to: rawRange.upperBound) - 1
                    guard sIdx < charToTokenIdx.count, eIdx < charToTokenIdx.count else { continue }
                    let ft = charToTokenIdx[sIdx]
                    let lt = charToTokenIdx[eIdx]
                    segStart = timeOffset + Double(tsPtr[ft])
                    segEnd = timeOffset + Double(tsPtr[lt]) + (r.durations != nil ? Double(r.durations![lt]) : 0.3)
                } else if let firstCh = trimmed.first,
                          let lastCh = trimmed.last,
                          let firstIdx = rawText.firstIndex(of: firstCh),
                          let lastIdx = rawText.lastIndex(of: lastCh),
                          firstIdx <= lastIdx {
                    let sIdx = rawText.distance(from: rawText.startIndex, to: firstIdx)
                    let eIdx = rawText.distance(from: rawText.startIndex, to: lastIdx)
                    guard sIdx < charToTokenIdx.count, eIdx < charToTokenIdx.count else { continue }
                    let ft = charToTokenIdx[sIdx]
                    let lt = charToTokenIdx[eIdx]
                    segStart = timeOffset + Double(tsPtr[ft])
                    segEnd = timeOffset + Double(tsPtr[lt]) + (r.durations != nil ? Double(r.durations![lt]) : 0.3)
                } else {
                    continue
                }

                allSegments.append(TranscriptSegment(
                    id: "\(meetingId)_\(chunkIdx)_\(j)",
                    startTime: max(segStart, 0), endTime: max(segEnd, segStart + 0.1),
                    text: trimmed, speakerLabel: "?", isFinal: true,
                    tokenTimestamps: tokenTs, lastTokenDuration: lastTokenDur))
            }

            AppLog.info("[FunASR] Window \(chunkIdx) [\(String(format: "%.1f", timeOffset))s-\(String(format: "%.1f", chunkEndTime))s]: \(sentences.count) sentences")

            } else if hasText, let fullText = r.text {
                let rawText = String(cString: fullText).toSimplifiedChinese()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawText.isEmpty else {
                    if chunkEnd >= totalSamples { break }
                    chunkStart = chunkEnd - overlapSamples
                    chunkIdx += 1
                    continue
                }

                // 标点恢复 + 分句（与 token 级路径相同逻辑）
                let punctuated = isPunctReady ? addPunctuation(rawText) : rawText
                let sentences = splitBySentences(punctuated)

                let rawLen = rawText.count

                for (j, sentence) in sentences.enumerated() {
                    let trimmed = sentence
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingPunctuation()
                    guard !trimmed.isEmpty else { continue }

                    // 比例时间戳：按字符位置在窗口内线性分配
                    let (segStart, segEnd): (Double, Double)
                    if rawLen > 0, let range = rawText.range(of: trimmed) {
                        let ratio0 = Double(rawText.distance(from: rawText.startIndex, to: range.lowerBound)) / Double(rawLen)
                        let ratio1 = Double(rawText.distance(from: rawText.startIndex, to: range.upperBound)) / Double(rawLen)
                        segStart = timeOffset + ratio0 * chunkDur
                        segEnd   = timeOffset + ratio1 * chunkDur
                    } else {
                        // 回退：按句子序号均匀分配
                        let ratio0 = Double(j) / Double(max(sentences.count, 1))
                        let ratio1 = Double(j + 1) / Double(max(sentences.count, 1))
                        segStart = timeOffset + ratio0 * chunkDur
                        segEnd   = timeOffset + ratio1 * chunkDur
                    }

                    // 收集所有句子，最后统一合并去重
                    allSegments.append(TranscriptSegment(
                        id: "\(meetingId)_\(chunkIdx)_\(j)",
                        startTime: max(segStart, 0),
                        endTime: max(segEnd, segStart + 0.1),
                        text: trimmed, speakerLabel: "?", isFinal: true))
                }

                AppLog.info("[FunASR] Window \(chunkIdx) fallback [\(String(format: "%.1f", timeOffset))s-\(String(format: "%.1f", chunkEndTime))s]: \(sentences.count) sentences")

            } else {
                AppLog.warn("[FunASR] Window \(chunkIdx): no tokens and no text")
            }

            if chunkEnd >= totalSamples { break }
            chunkStart = chunkEnd - overlapSamples
            chunkIdx += 1
        }

        AppLog.info("[FunASR] Complete: \(allSegments.count) raw sentences from \(chunkIdx + 1) windows, \(String(format: "%.1f", totalDuration))s audio")

        // === 合并去重：收集全部窗口句子 → 排序 → 合并重叠句 ===
        // 策略：时间重叠 + 文本相似 → 保留较长版本（解决跨窗口截断问题）
        allSegments.sort { $0.startTime < $1.startTime }
        var merged: [TranscriptSegment] = []
        for seg in allSegments {
            if let last = merged.last, seg.startTime < last.endTime {
                let sim = charJaccardSim(last.text, seg.text)
                if sim > 0.5 {
                    // 同一句：保留文本更长（更完整）的版本
                    if seg.text.count > last.text.count {
                        merged[merged.count - 1] = seg
                    }
                } else {
                    // 不同句子但时间重叠：都保留
                    merged.append(seg)
                }
            } else {
                merged.append(seg)
            }
        }

        totalSegments = merged.count
        AppLog.info("[FunASR] After merge: \(totalSegments) sentences")

        for seg in merged {
            onSegment(seg)
        }

        return totalSegments
    }

    /// 按句末标点分句
    private func splitBySentences(_ text: String) -> [String] {
        let pattern = "[。！？\\.!?；;]+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [text]
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)

        var sentences: [String] = []
        var lastEnd = 0
        for match in matches {
            let loc = match.range.location
            if loc > lastEnd {
                sentences.append(nsText.substring(with: NSRange(location: lastEnd, length: loc - lastEnd)))
            }
            lastEnd = loc + match.range.length
        }
        if lastEnd < nsText.length {
            sentences.append(nsText.substring(with: NSRange(location: lastEnd, length: nsText.length - lastEnd)))
        }
        return sentences
    }

    /// 字符级 Jaccard 相似度，用于跨窗口去重
    /// 返回值 0.0~1.0，>0.6 视为重复句
    private func charJaccardSim(_ a: String, _ b: String) -> Double {
        let setA = Set(a)
        let setB = Set(b)
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        guard union > 0 else { return 0 }
        // 同时考虑长度比例，避免短句被误杀
        let lenRatio = min(Double(a.count), Double(b.count)) / max(Double(a.count), Double(b.count))
        let jaccard = Double(intersection) / Double(union)
        return jaccard * 0.7 + lenRatio * 0.3
    }

    /// 为句子文本中的每个字符构建 Paraformer token 级时间戳数组。
    ///
    /// 返回值数组长度 = text.count，`result[i]` = text 第 i 个字符的音频时间（秒）。
    /// 标点字符（，。！？等）由 CT-Transformer 添加，无独立 token 时间戳，取最近非标点字符的时间。
    ///
    /// - Parameters:
    ///   - text: 最终句子文本（含标点）
    ///   - rawText: 标点恢复前的原始 token 文本
    ///   - charToTokenIdx: 原始文本字符 → token 索引映射
    ///   - tsPtr: Paraformer token 时间戳数组指针
    ///   - timeOffset: 当前音频 chunk 在整段音频中的时间偏移（秒）
    /// - Returns: 与 text 等长的 Double 数组，若映射失败返回 nil
    private nonisolated func buildTokenTimestamps(
        text: String,
        rawText: String,
        charToTokenIdx: [Int],
        tsPtr: UnsafePointer<Float>,
        timeOffset: Double
    ) -> [Double]? {
        let punctSet = Set<Character>(["，", "。", "！", "？", "；", "：", "、", ",", ".", "!", "?"])
        // 去除 text 中所有标点，得到与 rawText 完全对应的纯文本
        let stripped = String(text.filter { !punctSet.contains($0) })
        guard !stripped.isEmpty, let range = rawText.range(of: stripped) else {
            AppLog.info("[FunASR] buildTokenTimestamps: stripped text not found in rawText, falling back to ratio split")
            return nil
        }

        var rawPos = rawText.distance(from: rawText.startIndex, to: range.lowerBound)
        var timestamps: [Double] = []
        let rawCount = charToTokenIdx.count
        // 初始时间戳：第一个非标点字符的位置
        var lastTs = rawPos < rawCount ? timeOffset + Double(tsPtr[charToTokenIdx[rawPos]]) : timeOffset
        timestamps.reserveCapacity(text.count)

        for ch in text {
            if punctSet.contains(ch) {
                // 标点字符：沿用最近的非标点字符时间戳
                timestamps.append(lastTs)
            } else {
                // 非标点字符：从 rawText 当前位置取 token 时间戳
                if rawPos < rawCount {
                    let tokenIdx = charToTokenIdx[rawPos]
                    lastTs = timeOffset + Double(tsPtr[tokenIdx])
                    timestamps.append(lastTs)
                    rawPos += 1
                } else {
                    timestamps.append(lastTs)
                }
            }
        }
        return timestamps
    }

    // MARK: - Initialize Punctuation

    /// 初始化标点恢复模型
    /// - Parameter modelPath: CT-Transformer 模型文件路径 (model.onnx)
    func initializePunctuation(modelPath: String? = nil) throws {
        let path = modelPath ?? configuredPunctModelPath
        guard !path.isEmpty else {
            throw FunASRError.modelNotFound("标点模型路径未配置")
        }
        if isPunctReady && punctProcessor != nil && path == configuredPunctModelPath { return }

        destroyPunctuation()

        guard FileManager.default.fileExists(atPath: path) else {
            throw FunASRError.modelNotFound("标点模型文件不存在: \(path)")
        }

        try path.withCString { modelCStr in
            try "cpu".withCString { providerCStr in
                var config = SherpaOnnxOfflinePunctuationConfig()
                memset(&config, 0, MemoryLayout<SherpaOnnxOfflinePunctuationConfig>.size)
                config.model.ct_transformer = modelCStr
                config.model.num_threads = 1
                config.model.provider = providerCStr
                config.model.debug = 0

                guard let punct = SherpaOnnxCreateOfflinePunctuation(&config) else {
                    throw FunASRError.initializationFailed("创建标点恢复处理器失败")
                }
                self.punctProcessor = punct
                self.configuredPunctModelPath = path
                self.isPunctReady = true
                AppLog.info("[FunASR] Punctuation model initialized: \(path)")
            }
        }
    }

    /// 为文本添加标点（CT-Transformer 后处理）
    /// - Parameter text: 无标点的原始文本
    /// - Returns: 添加标点后的文本，若失败返回原文本
    func addPunctuation(_ text: String) -> String {
        guard let punct = punctProcessor, !text.isEmpty else { return text }

        return text.withCString { cStr in
            guard let result = SherpaOfflinePunctuationAddPunct(punct, cStr) else {
                return text
            }
            defer { SherpaOfflinePunctuationFreeText(result) }
            return String(cString: result)
        }
    }

    // MARK: - VAD (Voice Activity Detection)

    /// 初始化 Silero VAD 语音活动检测器
    /// - Parameter modelPath: silero_vad.onnx 模型文件路径
    func initializeVAD(modelPath: String? = nil) throws {
        let path = modelPath ?? configuredVadModelPath
        guard !path.isEmpty else {
            throw FunASRError.modelNotFound("VAD 模型路径未配置")
        }
        if isVadReady && vadDetector != nil && path == configuredVadModelPath { return }

        destroyVAD()

        guard FileManager.default.fileExists(atPath: path) else {
            throw FunASRError.modelNotFound("VAD 模型文件不存在: \(path)")
        }

        try path.withCString { modelCStr in
            try "cpu".withCString { providerCStr in
                var config = SherpaOnnxVadModelConfig()
                memset(&config, 0, MemoryLayout<SherpaOnnxVadModelConfig>.size)

                config.silero_vad.model = modelCStr
                config.silero_vad.threshold = SettingsManager.shared.vadThreshold
                config.silero_vad.min_silence_duration = Float(SettingsManager.shared.pauseWindow)
                config.silero_vad.min_speech_duration = 0.5
                config.silero_vad.max_speech_duration = 30.0
                config.silero_vad.window_size = 512
                config.sample_rate = 16000
                config.num_threads = 1
                config.provider = providerCStr
                config.debug = 0

                guard let vad = SherpaOnnxCreateVoiceActivityDetector(&config, 30.0) else {
                    throw FunASRError.initializationFailed("创建 VAD 检测器失败")
                }
                self.vadDetector = vad
                self.configuredVadModelPath = path
                self.isVadReady = true
                AppLog.info("[FunASR] VAD initialized: \(path)")
            }
        }
    }

    func destroyVAD() {
        if let vad = vadDetector {
            SherpaOnnxDestroyVoiceActivityDetector(vad)
            vadDetector = nil
        }
        isVadReady = false
    }

    // MARK: - WAV Loading

    /// 从 WAV 文件加载 PCM 样本（使用 sherpa-onnx 内置读取器）
    private func loadWAVSamples(from url: URL) throws -> (samples: [Float], sampleRate: Int32) {
        return try url.path.withCString { pathCStr in
            guard let wave = SherpaOnnxReadWave(pathCStr) else {
                // 回退：尝试用 AVAudioFile 读取非 WAV 格式
                return try loadAudioWithAVFoundation(from: url)
            }
            defer { SherpaOnnxFreeWave(wave) }

            let w = wave.pointee
            guard w.num_samples > 0 else {
                throw FunASRError.audioLoadFailed("音频文件无样本数据: \(url.lastPathComponent)")
            }
            let samples = Array(UnsafeBufferPointer(start: w.samples, count: Int(w.num_samples)))
            return (samples, w.sample_rate)
        }
    }

    /// 使用 AVAudioFile 读取并重采样到 16kHz（回退方案）
    private func loadAudioWithAVFoundation(from url: URL) throws -> (samples: [Float], sampleRate: Int32) {
        let file = try AVAudioFile(forReading: url)

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw FunASRError.audioLoadFailed("无法创建 16kHz 音频格式")
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw FunASRError.audioLoadFailed("无法创建音频缓冲区")
        }

        try file.read(into: buffer)

        let samples: [Float]
        if file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1,
           file.processingFormat.commonFormat == .pcmFormatFloat32,
           let channelData = buffer.floatChannelData?[0] {
            samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
            return (samples, 16000)
        }

        // 需要重采样
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw FunASRError.audioLoadFailed("无法创建音频转换器")
        }

        let outputCapacity = AVAudioFrameCount(Double(frameCount) * 16000.0 / file.processingFormat.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputCapacity) else {
            throw FunASRError.audioLoadFailed("无法创建输出缓冲区")
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error { throw error }

        let channelData = outputBuffer.floatChannelData![0]
        samples = Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
        return (samples, 16000)
    }

    // MARK: - Cleanup

    func destroyOnlineStream() {
        if let stream = onlineStream {
            SherpaOnnxDestroyOnlineStream(stream)
            onlineStream = nil
        }
        lastDecodedText = ""
    }

    func destroyOnline() {
        destroyOnlineStream()
        if let rec = onlineRecognizer {
            SherpaOnnxDestroyOnlineRecognizer(rec)
            onlineRecognizer = nil
        }
        isOnlineReady = false
    }

    func destroyOffline() {
        if let rec = offlineRecognizer {
            SherpaOnnxDestroyOfflineRecognizer(rec)
            offlineRecognizer = nil
        }
        isOfflineReady = false
    }

    func destroyPunctuation() {
        if let punct = punctProcessor {
            SherpaOnnxDestroyOfflinePunctuation(punct)
            punctProcessor = nil
        }
        isPunctReady = false
    }

    /// 释放所有模型
    func reset() {
        destroyOnline()
        destroyOffline()
        destroyPunctuation()
        destroyVAD()
        AppLog.info("[FunASR] All models released")
    }
}

// MARK: - Errors

enum FunASRError: LocalizedError {
    case modelNotFound(String)
    case initializationFailed(String)
    case notInitialized(String)
    case processingFailed(String)
    case audioLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let msg): return "FunASR 模型未找到: \(msg)"
        case .initializationFailed(let msg): return "FunASR 初始化失败: \(msg)"
        case .notInitialized(let msg): return "FunASR 未初始化: \(msg)"
        case .processingFailed(let msg): return "FunASR 处理失败: \(msg)"
        case .audioLoadFailed(let msg): return "FunASR 音频加载失败: \(msg)"
        }
    }
}

// MARK: - String Extension

extension String {
    /// 繁体中文转简体（使用 CFStringTransform 的 Hant-Hans 映射）
    func toSimplifiedChinese() -> String {
        let mutable = NSMutableString(string: self)
        CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
        return mutable as String
    }

    /// 去除首尾标点符号（句首逗号等 CT-Transformer 可能引入的残留标点）
    func trimmingPunctuation() -> String {
        let punctSet = CharacterSet(charactersIn: "，,。！？.!?；;：:、")
        return self.trimmingCharacters(in: punctSet)
    }
}
