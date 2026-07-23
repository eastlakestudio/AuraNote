import AVFoundation
import WhisperKit

/// 音频录制 + 基于 WhisperKit 的本地实时转写服务
/// 流水线：始终录音 → 静默切割为 AudioChunk → 异步转写回填文本 → 声纹事后处理
@Observable
final class AudioRecorder {

    // MARK: - 公开状态

    var isRecording = false
    var audioChunks: [AudioChunk] = []     // 根据静默切割的音频片段列表
    var currentAmplitude: Float = 0.0       // 用于音量可视化（0.0 ~ 1.0）
    var isListening: Bool = false            // 当前是否有语音活动（用于 UI 指示器）
    var errorMessage: String?

    /// 联系人提供者：返回 [(id, name, embedding)] 用于实时声纹匹配
    var contactsProvider: (() async -> [(id: String, name: String, embedding: [Float])])?
    /// 声纹匹配成功回调：自动将匹配到的联系人添加为会议参会人
    var onSpeakerMatched: ((_ contactId: String, _ contactName: String) -> Void)?

    // MARK: - 私有属性

    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var audioConverter: AVAudioConverter?
    
    private var recordingStartTime: Date?
    private var currentMeetingId: String?

    // 音频切割流水线
    private var currentChunkBuffer: [Float] = []   // 当前片段的累积音频
    private var currentChunkStartTime: Date?        // 当前片段的首个语音时间
    private var chunkCounter: Int = 0               // 片段序号
    private var pauseTimer: Timer?                  // 静默计时器，触发后切割片段
    private var incrementalClustering = IncrementalSpeakerClustering()  // 增量声纹聚类（同会议未知说话人自动关联）

    // 30 秒连续 VAD 攒批声纹提取队列
    private var pendingVoiceprintChunks: [AudioChunk] = []
    private var pendingVoiceprintDuration: Double = 0.0
    private let voiceprintBatchLock = NSLock()

    init() {}

    // MARK: - 权限请求

    func requestPermissions() async -> Bool {
        let micGranted: Bool
        #if os(iOS)
        if #available(iOS 17.0, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        micGranted = true
        #endif
        guard micGranted else {
            errorMessage = loc("mic_permission_required")
            return false
        }
        return true
    }

    // MARK: - 开始录音

    func startRecording(meetingId: String, savePath: URL, contextualStrings: [String] = []) throws {
        // 重置状态
        audioChunks = []
        errorMessage = nil
        currentChunkBuffer = []
        currentChunkStartTime = nil
        chunkCounter = 0
        isListening = false
        currentMeetingId = meetingId
        pauseTimer?.invalidate()
        pauseTimer = nil
        voiceprintBatchLock.withLock {
            pendingVoiceprintChunks = []
            pendingVoiceprintDuration = 0.0
        }
        Task { await incrementalClustering.reset() }
        
        let s = SettingsManager.shared
        AppLog.info("[AudioRecorder Params] silenceThreshold=\(s.silenceThreshold) pauseWindow=\(s.pauseWindow)s liveTranscribeInterval=\(s.liveTranscribeInterval)s maxChunkDuration=\(s.maxChunkDuration)s noiseGate=\(s.noiseGate) targetPeak=\(s.targetPeak) maxGain=\(s.maxGain) baseGain=\(s.baseGain) liveMatchingThreshold=\(s.liveMatchingThreshold) matchingThreshold=\(s.matchingThreshold) highConfThreshold=\(s.highConfidenceThreshold)")

        // 配置 Audio Session (仅 iOS)
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        let wavSavePath = savePath.deletingPathExtension().appendingPathExtension("wav")
        let saveFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        audioFile = try AVAudioFile(
            forWriting: wavSavePath,
            settings: saveFormat.settings
        )
        
        self.audioConverter = AVAudioConverter(from: recordingFormat, to: saveFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            // VAD 用原始振幅判停，避免增益抬升底噪导致误判为持续说话
            let rawAmplitude = self.computeAmplitude(buffer: buffer)
            
            // 针对语音做自适应增强：有说话时强力增益，静音时不放大噪声
            let gainedBuffer = self.applySpeechEnhancement(to: buffer)
            
            // 统一转换为 16000 Hz
            let resampledBuffer: AVAudioPCMBuffer
            if let converter = self.audioConverter {
                do {
                    resampledBuffer = try AudioProcessor.resampleBuffer(gainedBuffer, with: converter)
                } catch {
                    return
                }
            } else {
                resampledBuffer = gainedBuffer
            }
            
            // 写入 16000 Hz WAV 文件
            do {
                try self.audioFile?.write(from: resampledBuffer)
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = String(format: "音频写入失败: %@", error.localizedDescription)
                }
            }
            // 可视化用原始振幅（EMA 平滑）
            self.currentAmplitude = self.currentAmplitude * 0.7 + rawAmplitude * 0.3
            
            let floatArray = AudioProcessor.convertBufferToArray(buffer: resampledBuffer)
            
            // VAD 用未平滑的原始振幅，即时响应停顿，避免长句不切分
            self.appendAudioAndSegment(floatArray, rawAmplitude: rawAmplitude)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recordingStartTime = Date()
        isRecording = true
    }

    // MARK: - 停止录音

    func stopRecording() -> Int {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        audioFile = nil
        audioConverter = nil
        
        // 切割最后一个未完成的片段
        if !currentChunkBuffer.isEmpty {
            cutCurrentChunk()
        }
        
        pauseTimer?.invalidate()
        pauseTimer = nil

        let duration: Int
        if let start = recordingStartTime {
            duration = Int(Date().timeIntervalSince(start))
        } else {
            duration = 0
        }

        isRecording = false
        currentAmplitude = 0

        // 刷出剩余末尾未满 30 秒的声纹批次
        var finalBatch: [AudioChunk]?
        var finalDuration: Double = 0.0
        voiceprintBatchLock.withLock {
            if !pendingVoiceprintChunks.isEmpty {
                finalBatch = pendingVoiceprintChunks
                finalDuration = pendingVoiceprintDuration
                pendingVoiceprintChunks = []
                pendingVoiceprintDuration = 0.0
            }
        }
        if let batch = finalBatch {
            Task { [weak self] in
                await self?.processVoiceprintBatch(batch, batchDuration: finalDuration)
                let _ = await self?.incrementalClustering.mergeSimilarClusters(threshold: SettingsManager.shared.clusterMergeDistance)
            }
        } else {
            Task { [weak self] in
                let _ = await self?.incrementalClustering.mergeSimilarClusters(threshold: SettingsManager.shared.clusterMergeDistance)
            }
        }

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif

        return duration
    }

    // MARK: - 内部方法

    // MARK: - 音频分割（VAD 纯分割器，不参与录制决策）

    /// 始终追加音频到当前片段 buffer，VAD 仅用于判断何时切割
    /// - Parameter rawAmplitude: 原始振幅（未经 EMA 平滑），用于即时停顿检测
    private func appendAudioAndSegment(_ audio: [Float], rawAmplitude: Float) {
        DispatchQueue.main.async {
            self.currentChunkBuffer.append(contentsOf: audio)
            
            let settings = SettingsManager.shared
            if rawAmplitude > settings.silenceThreshold {
                // 有语音活动：记录片段起始时间，重置静默计时器
                let now = Date()
                if self.currentChunkStartTime == nil {
                    self.currentChunkStartTime = now
                }
                self.isListening = true
                self.pauseTimer?.invalidate()
                self.pauseTimer = Timer.scheduledTimer(withTimeInterval: settings.pauseWindow, repeats: false) { [weak self] _ in
                    self?.cutCurrentChunk()
                }
                
                // 超过最大时长强制切分（防止连续说话导致单段过长）
                let chunkDuration = Double(self.currentChunkBuffer.count) / Double(WhisperKit.sampleRate)
                if chunkDuration >= settings.maxChunkDuration {
                    self.cutCurrentChunk()
                }
            } else {
                // 静默：不做任何事，等待 pauseTimer 触发切割
                // 如果从未有过语音活动（pauseTimer 从未创建），丢弃过长的纯静音
                if self.pauseTimer == nil && self.currentChunkStartTime == nil {
                    let maxSilentSamples = 16000 * 2
                    let keepSamples = 8000
                    if self.currentChunkBuffer.count > maxSilentSamples {
                        self.currentChunkBuffer = Array(self.currentChunkBuffer.suffix(keepSamples))
                    }
                }
            }
        }
    }

    /// 切割当前音频片段：创建 AudioChunk 加入列表，投递异步转写
    private func cutCurrentChunk() {
        guard let meetingId = currentMeetingId, let start = recordingStartTime else { return }
        guard !currentChunkBuffer.isEmpty else {
            // 空片段（纯静音后触发），只重置状态
            currentChunkStartTime = nil
            isListening = false
            return
        }

        // 检查片段是否有足够的语音能量（过滤纯噪声片段，防止 Whisper 幻觉）
        let avgEnergy = currentChunkBuffer.reduce(0) { $0 + abs($1) } / Float(currentChunkBuffer.count)
        let minSpeechEnergy: Float = 0.003  // 低于此值视为纯噪声，不创建片段
        guard avgEnergy >= minSpeechEnergy else {
            AppLog.info("Discarded low-energy noise segment avgEnergy=\(String(format: "%.5f", avgEnergy))")
            currentChunkBuffer = []
            currentChunkStartTime = nil
            isListening = false
            return
        }
        
        let now = Date()
        let chunkStartTime = currentChunkStartTime?.timeIntervalSince(start) ?? max(0, now.timeIntervalSince(start) - Double(currentChunkBuffer.count) / Double(WhisperKit.sampleRate))
        let chunkEndTime = now.timeIntervalSince(start)
        
        let chunk = AudioChunk(
            id: "\(meetingId)_chunk_\(chunkCounter)",
            meetingId: meetingId,
            startTime: chunkStartTime,
            endTime: chunkEndTime,
            audioSamples: currentChunkBuffer,
            text: nil,
            isTranscribing: false,
            speakerLabel: nil
        )
        
        chunkCounter += 1
        audioChunks.append(chunk)
        
        // 重置当前片段状态
        currentChunkBuffer = []
        currentChunkStartTime = nil
        isListening = false
        
        // 异步投递转写任务
        let capturedChunk = chunk
        Task { [weak self] in
            await self?.transcribeChunk(capturedChunk)
        }
    }

    /// 异步转写单个音频片段，完成后回填 text
    private func transcribeChunk(_ chunk: AudioChunk) async {
        // 标记为转写中
        await MainActor.run {
            guard let idx = self.audioChunks.firstIndex(where: { $0.id == chunk.id }) else { return }
            self.audioChunks[idx].isTranscribing = true
        }
        
        // 等待模型就绪
        guard await WhisperService.shared.isReady else {
            AppLog.warn("Transcribe chunk \(chunk.id) failed: model not ready")
            await MainActor.run {
                guard let idx = self.audioChunks.firstIndex(where: { $0.id == chunk.id }) else { return }
                self.audioChunks[idx].isTranscribing = false
            }
            return
        }
        
        do {
            let text = try await WhisperService.shared.transcribeLive(audioArray: chunk.audioSamples)
            let trimmed = text.trimmingCharacters(in: .whitespaces)

            // 防止 Whisper 静音幻觉：过滤异常长文本或明显错误的输出
            if isHallucination(trimmed, chunk: chunk) {
                AppLog.info("Discarded suspected hallucination text: \"\(trimmed.prefix(50))...\"")
                await MainActor.run {
                    guard let idx = self.audioChunks.firstIndex(where: { $0.id == chunk.id }) else { return }
                    self.audioChunks[idx].isTranscribing = false
                }
                return
            }

            await MainActor.run {
                guard let idx = self.audioChunks.firstIndex(where: { $0.id == chunk.id }) else { return }
                // 空文本用 "" 而非 nil，UI 可据此区分「已处理但无内容」vs「尚未处理」
                self.audioChunks[idx].text = trimmed.isEmpty ? "" : trimmed
                self.audioChunks[idx].isTranscribing = false
            }

            // 投递入 30 秒连续 VAD 攒批队列，提取稳定高精度声纹
            if trimmed.isEmpty { return }
            enqueueChunkForVoiceprintBatch(chunk)
        } catch {
            AppLog.warn("Transcribe chunk \(chunk.id) failed: \(error.localizedDescription)")
            await MainActor.run {
                guard let idx = self.audioChunks.firstIndex(where: { $0.id == chunk.id }) else { return }
                self.audioChunks[idx].isTranscribing = false
            }
        }
    }

    /// 检测 Whisper 静音幻觉：短音频产出异常长文本，或包含明显训练数据残留
    private func isHallucination(_ text: String, chunk: AudioChunk) -> Bool {
        guard !text.isEmpty else { return false }

        let duration = chunk.endTime - chunk.startTime
        // 正常语速约 3-5 字/秒。若超过 20 字/秒，极可能是幻觉
        let charsPerSecond = Double(text.count) / max(duration, 0.5)
        if charsPerSecond > 20 {
            return true
        }

        // 常见 Whisper 幻觉模式（训练数据中的直播/视频用语残留）
        let hallucinationPatterns = [
            "点赞", "订阅", "转发", "打赏", "关注",
            "一键三连", "弹幕", "评论区",
            "请不吝", "明镜与点点",
            "Thank you for watching", "Please subscribe",
        ]
        for pattern in hallucinationPatterns {
            if text.contains(pattern) {
                return true
            }
        }

        return false
    }

    /// 将转写完成的片段存入 30 秒攒批池，当攒满 30 秒连续 VAD 语音时批量提取高精声纹
    private func enqueueChunkForVoiceprintBatch(_ chunk: AudioChunk) {
        var batchToProcess: [AudioChunk]?
        var totalDuration: Double = 0.0
        
        voiceprintBatchLock.withLock {
            pendingVoiceprintChunks.append(chunk)
            let dur = max(0.5, chunk.endTime - chunk.startTime)
            pendingVoiceprintDuration += dur
            
            // 攒满 8 秒连续 VAD 语音（或不少于 4 个句段）触发一次高精声纹提取，实现全覆盖与秒级响应
            if pendingVoiceprintDuration >= 8.0 || pendingVoiceprintChunks.count >= 4 {
                batchToProcess = pendingVoiceprintChunks
                totalDuration = pendingVoiceprintDuration
                pendingVoiceprintChunks = []
                pendingVoiceprintDuration = 0.0
            }
        }
        
        if let batch = batchToProcess {
            Task { [weak self] in
                await self?.processVoiceprintBatch(batch, batchDuration: totalDuration)
            }
        }
    }

    /// 批量处理 30 秒连续 VAD 音频切片，提取高清晰度 192D ERes2Net 声纹并更新所有子切片
    private func processVoiceprintBatch(_ batch: [AudioChunk], batchDuration: Double) async {
        guard !batch.isEmpty else { return }
        
        var combinedSamples: [Float] = []
        var chunkSampleOffsets: [(chunkId: String, startSec: Double, endSec: Double)] = []
        var currentSampleOffset = 0
        
        for chunk in batch {
            let startSec = Double(currentSampleOffset) / 16000.0
            combinedSamples.append(contentsOf: chunk.audioSamples)
            currentSampleOffset += chunk.audioSamples.count
            let endSec = Double(currentSampleOffset) / 16000.0
            chunkSampleOffsets.append((chunkId: chunk.id, startSec: startSec, endSec: endSec))
        }
        guard !combinedSamples.isEmpty else { return }
        
        AppLog.info("[AudioRecorder] Voiceprint Hybrid Batch start: count=\(batch.count), dur=\(String(format: "%.1f", batchDuration))s, totalSamples=\(combinedSamples.count)")
        
        // 1. 调用混合链路进行精细分离
        let hybridSegments = await DiarizationService.shared.extractHybridSegments(from: combinedSamples)
        if hybridSegments.isEmpty {
            AppLog.warn("[AudioRecorder] Voiceprint batch hybrid extraction returned empty")
            return
        }
        
        let contacts = await contactsProvider?() ?? []
        var matchedContactIds: Set<String> = []
        
        // 2. 将精细子片段分配标签
        var labeledSubSegments: [(start: Double, end: Double, label: String, embedding: [Float])] = []
        
        for sub in hybridSegments {
            var assignedLabel: String
            if !contacts.isEmpty, let match = DiarizationService.matchSingleEmbedding(
                sub.embedding, against: contacts,
                threshold: SettingsManager.shared.liveMatchingThreshold
            ) {
                assignedLabel = match.contactName
                matchedContactIds.insert(match.contactId)
            } else {
                let duration = sub.end - sub.start
                assignedLabel = await incrementalClustering.addEmbedding(sub.embedding, duration: duration)
            }
            
            labeledSubSegments.append((
                start: sub.start, 
                end: sub.end, 
                label: assignedLabel, 
                embedding: sub.embedding
            ))
        }
        
        // 2.5 同说话人重叠片段合并去重 (防止底层多轨识别带来的双倍计分)
        var mergedLabeledSegments: [(start: Double, end: Double, label: String, embedding: [Float])] = []
        let groupedByLabel = Dictionary(grouping: labeledSubSegments, by: { $0.label })
        
        for (label, group) in groupedByLabel {
            let sorted = group.sorted { $0.start < $1.start }
            var currentMerged: [(start: Double, end: Double, label: String, embedding: [Float])] = []
            
            for seg in sorted {
                if let last = currentMerged.last, seg.start <= last.end + 0.1 {
                    currentMerged[currentMerged.count - 1] = (
                        start: last.start,
                        end: max(last.end, seg.end),
                        label: label,
                        embedding: last.embedding
                    )
                } else {
                    currentMerged.append(seg)
                }
            }
            mergedLabeledSegments.append(contentsOf: currentMerged)
        }
        mergedLabeledSegments.sort { $0.start < $1.start }
        
        // 3. 时间重叠分配逻辑 (Overlap Matching) 寻找主导说话人
        var chunkUpdates: [String: (label: String, embedding: [Float])] = [:]
        
        for offset in chunkSampleOffsets {
            var speakerDurations: [String: Double] = [:]
            var bestEmbedding: [Float]? = nil
            
            for sub in mergedLabeledSegments {
                let overlapStart = max(offset.startSec, sub.start)
                let overlapEnd = min(offset.endSec, sub.end)
                if overlapStart < overlapEnd {
                    let overlapDuration = overlapEnd - overlapStart
                    speakerDurations[sub.label, default: 0.0] += overlapDuration
                    if bestEmbedding == nil || speakerDurations[sub.label]! == speakerDurations.values.max() {
                        bestEmbedding = sub.embedding
                    }
                }
            }
            
            if let dominantSpeaker = speakerDurations.max(by: { $0.value < $1.value })?.key {
                chunkUpdates[offset.chunkId] = (label: dominantSpeaker, embedding: bestEmbedding ?? [])
            } else {
                // 若无任何重叠，退化为取最长的子片段兜底
                if let longestSub = mergedLabeledSegments.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
                    chunkUpdates[offset.chunkId] = (label: longestSub.label, embedding: longestSub.embedding)
                }
            }
        }
        
        // 4. 应用回 UI 层
        await MainActor.run {
            for i in 0..<self.audioChunks.count {
                let chunkId = self.audioChunks[i].id
                if let update = chunkUpdates[chunkId] {
                    self.audioChunks[i].speakerLabel = update.label
                    self.audioChunks[i].embedding = update.embedding
                }
            }
        }
        
        for contactId in matchedContactIds {
            onSpeakerMatched?(contactId, "KnownContact") 
        }
    }

    /// 为已转写的片段提取声纹并匹配已知联系人（单切片回退方法）
    private func matchSpeakerForChunk(_ chunk: AudioChunk) async {
        guard let provider = contactsProvider else {
            AppLog.info("Voiceprint matching: contactsProvider not set")
            return
        }
        let contacts = await provider()
        guard !contacts.isEmpty else {
            AppLog.info("Voiceprint matching: contacts list empty (no contacts with stored voiceprints)")
            return
        }
        AppLog.info("Voiceprint matching: \(contacts.count) candidates, chunk duration \(String(format: "%.1f", chunk.endTime - chunk.startTime))s")

        guard let embedding = await DiarizationService.shared.extractEmbedding(from: chunk.audioSamples) else {
            AppLog.info("Voiceprint matching: embedding extraction failed")
            return
        }

        // 始终保存 embedding 到 chunk（供离线分析回退复用）
        await MainActor.run {
            guard let idx = self.audioChunks.firstIndex(where: { $0.id == chunk.id }) else { return }
            self.audioChunks[idx].embedding = embedding
        }

        guard let match = DiarizationService.matchSingleEmbedding(
            embedding, against: contacts,
            threshold: SettingsManager.shared.liveMatchingThreshold
        ) else {
            // 未匹配已知联系人 → 增量聚类自动关联同会议未知说话人
            let label = await incrementalClustering.addEmbedding(embedding)
            AppLog.info("Voiceprint clustering: assigned \(label) (threshold=\(SettingsManager.shared.liveMatchingThreshold))")
            await MainActor.run {
                guard let idx = self.audioChunks.firstIndex(where: { $0.id == chunk.id }) else { return }
                self.audioChunks[idx].speakerLabel = label
            }
            return
        }

        await MainActor.run {
            guard let idx = self.audioChunks.firstIndex(where: { $0.id == chunk.id }) else { return }
            self.audioChunks[idx].speakerLabel = match.contactName
        }
        AppLog.info("Voiceprint matched: \(match.contactName) (score=\(String(format: "%.3f", match.score)))")
        
        // 自动将匹配到的联系人添加为会议参会人
        onSpeakerMatched?(match.contactId, match.contactName)
    }

    /// 计算原始音频的平均幅度（用于 VAD 静音检测，不受增益干扰）
    private func computeAmplitude(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += abs(channelData[i])
        }
        return sum / Float(frameLength)
    }
    
    /// 自适应语音增强：根据缓冲区峰值电平动态计算增益
    /// - 有语音时（峰值 > 噪声门限）：放大到目标峰值 -3dBFS，最大增益 10x
    /// - 静音/纯噪声时（峰值 ≤ 门限）：不做放大，避免抬升底噪
    private func applySpeechEnhancement(to buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return buffer }
        
        // 找到当前 buffer 的峰值幅度
        var peak: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            guard let data = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<frameLength {
                peak = max(peak, abs(data[i]))
            }
        }
        
        // 语音增强参数（可在系统配置中调节）
        let settings = SettingsManager.shared
        let noiseGate: Float = settings.noiseGate    // 低于此峰值视为静音/噪声，不做增益
        let targetPeak: Float = settings.targetPeak   // 目标峰值 -3dBFS
        let maxGain: Float = settings.maxGain         // 最大增益倍数，防止极端放大
        let baseGain: Float = settings.baseGain       // 中高电平语音的基础增益
        
        let gain: Float
        if peak > noiseGate {
            // 有语音：计算将峰值推到目标所需的增益，加上基础增益
            let neededGain = targetPeak / peak
            gain = min(maxGain, max(baseGain, neededGain))
        } else {
            // 静音/底噪：仅保留原始电平，不做放大
            gain = 1.0
        }
        
        // 应用增益到输出 buffer
        guard let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return buffer
        }
        output.frameLength = buffer.frameLength
        
        for ch in 0..<Int(buffer.format.channelCount) {
            guard let inputData = buffer.floatChannelData?[ch],
                  let outputData = output.floatChannelData?[ch] else { continue }
            for i in 0..<frameLength {
                let sample = inputData[i] * gain
                outputData[i] = max(-1.0, min(1.0, sample))  // 硬限幅防破音
            }
        }
        return output
    }
}

// MARK: - 错误类型

enum RecorderError: LocalizedError {
    case microphoneAccessDenied

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied: return loc("mic_permission_denied")
        }
    }
}
