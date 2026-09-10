import AVFoundation
import CSherpaOnnx

/// 音频录制 + 基于 sherpa-onnx FunASR（伪流式 + 离线 Paraformer）的本地实时转写服务
/// 流水线：始终录音 → FunASR 流式转写 + VAD 静默切割（声纹） → 声纹事后处理
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
    /// 增量聚类发现新匿名说话人回调（实时添加为参会人）
    var onNewSpeakerDiscovered: ((String) -> Void)?
    /// 段声纹分离完成回调
    var onVoiceprintLabelsUpdated: (() -> Void)?
    /// 语音转写引擎（本地 FunASR 或云端大模型）
    var transcriptionEngine: TranscriptionEngineType = .localFunASR

    // MARK: - 私有属性

    /// 已通过 onNewSpeakerDiscovered 通知过的匿名说话人标签，避免重复添加
    private var discoveredSpeakerLabels: Set<String> = []

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

    // FunASR 伪流式转写
    private var funasrAccumulatedText: String = ""  // 当前段累积文本
    private var funasrDecodeTimer: Timer?            // 伪流式推理轮询定时器
    private var funasrStreamCreated = false           // 伪流式缓冲区是否已创建
    private var isInferring = false                   // 推理防重入锁
    private var lastSpeechSampleIndex: Int = 0        // VAD 最后语音位置
    private var silenceSampleCount: Int = 0            // VAD 连续静音采样计数
    private var lastPauseSampleIndex: Int = 0          // 最近一次语音->静音切换位置
    private var lastChunkEndTime: TimeInterval = 0     // 上个产出段的结束时间

    // 30 秒连续 VAD 攒批声纹提取队列
    private var pendingVoiceprintChunks: [AudioChunk] = []
    private var pendingVoiceprintDuration: Double = 0.0
    private let voiceprintBatchLock = NSLock()

    init() {}

    // MARK: - 权限请求

    func requestPermissions() async -> Bool {
        var micGranted: Bool
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
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            micGranted = true
        case .notDetermined:
            micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            // .denied 或 .restricted
            micGranted = false
        }
        #endif
        
        guard micGranted else {
            errorMessage = loc("mic_permission_required")
            return false
        }
        return true
    }

    func startRecording(meetingId: String, savePath: URL, hotwords: String = "", engine: TranscriptionEngineType? = nil) throws {
        self.transcriptionEngine = engine ?? SettingsManager.shared.transcriptionEngine
        AppLog.info("[AudioRecorder] Starting recording with engine=\(self.transcriptionEngine.rawValue)")
        if self.transcriptionEngine == .cloudModel {
            if let (cloudModel, _) = TranscriptionEngineCoordinator.shared.getActiveCloudTranscriptionModel() {
                AppLog.info("[AudioRecorder] Active cloud model: \(cloudModel.name) (\(cloudModel.modelName))")
            } else {
                AppLog.warn("[AudioRecorder] Cloud engine selected, but no audio model with API-KEY found in Keychain!")
            }
        }
        // 重置状态
        audioChunks = []
        errorMessage = nil
        currentChunkBuffer = []
        currentChunkStartTime = nil
        chunkCounter = 0
        isListening = false
        lastSpeechSampleIndex = 0
        silenceSampleCount = 0
        lastPauseSampleIndex = 0
        lastChunkEndTime = 0
        currentMeetingId = meetingId
        pauseTimer?.invalidate()
        pauseTimer = nil
        voiceprintBatchLock.withLock {
            pendingVoiceprintChunks = []
            pendingVoiceprintDuration = 0.0
        }
        discoveredSpeakerLabels = []
        funasrAccumulatedText = ""
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
            let rawFloatArray = AudioProcessor.convertBufferToArray(buffer: buffer)  // 原始振幅，VAD 用
            
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
                Task { @MainActor [weak self] in
                    self?.errorMessage = String(format: "音频写入失败: %@", error.localizedDescription)
                }
            }
            
            let floatArray = AudioProcessor.convertBufferToArray(buffer: resampledBuffer)
            
            // 喂入 FunASR 流式 Paraformer（异步，不阻塞音频线程）
            if self.funasrStreamCreated {
                let samples = floatArray
                Task { await FunASRService.shared.acceptWaveform(samples: samples) }
            }
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // 可视化用原始振幅（EMA 平滑）
                self.currentAmplitude = self.currentAmplitude * 0.7 + rawAmplitude * 0.3
                // VAD 用原始振幅，语音识别用增益后音频
                self.appendAudioAndSegment(floatArray, rawAudio: rawFloatArray)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        // 仅在本地 FunASR 模式下初始化 FunASR 流式 Paraformer 并创建在线流与解码轮询
        if self.transcriptionEngine == .localFunASR {
            Task { [weak self] in
                guard let self = self else { return }
                do {
                    try await FunASRService.shared.initializeOnline(hotwords: hotwords)
                    try await FunASRService.shared.createOnlineStream()
                    await MainActor.run {
                        self.funasrStreamCreated = true
                        AppLog.info("[AudioRecorder] FunASR online stream created")
                    }
                } catch {
                    AppLog.error("[AudioRecorder] FunASR online init failed: \(error)")
                }
            }

            // 伪流式推理轮询定时器：频率跟随 liveTranscribeInterval（默认 1.5s）
            funasrDecodeTimer?.invalidate()
            let decodeInterval = Double(SettingsManager.shared.liveTranscribeInterval)
            funasrDecodeTimer = Timer.scheduledTimer(withTimeInterval: decodeInterval, repeats: true) { [weak self] _ in
                guard let self = self, self.funasrStreamCreated, !self.isInferring else { return }
                self.isInferring = true
                Task { [weak self] in
                    guard let self = self else { return }
                    if let incremental = await FunASRService.shared.decodeStreamIncremental(), !incremental.isEmpty {
                        await MainActor.run {
                            self.funasrAccumulatedText += incremental
                        }
                    }
                    await MainActor.run { self.isInferring = false }
                }
            }
        }

        recordingStartTime = Date()
        isRecording = true
    }

    // MARK: - 停止录音

    /// 仅停止音频引擎（在后台线程调用），不碰任何 @Observable 状态，避免数据竞争
    func stopRecordingEngine() -> Int {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioFile = nil
        audioConverter = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
        let duration: Int
        if let start = recordingStartTime {
            duration = Int(Date().timeIntervalSince(start))
        } else {
            duration = 0
        }
        return duration
    }

    /// 录音引擎停止后的状态清理（主线程调用）
    func finalizeRecording() {
        // 切割最后一个未完成的片段
        if !currentChunkBuffer.isEmpty {
            if currentChunkStartTime == nil {
                currentChunkBuffer = []
            } else {
                cutCurrentChunk()
            }
        }
        
        pauseTimer?.invalidate()
        pauseTimer = nil

        funasrDecodeTimer?.invalidate()
        funasrDecodeTimer = nil

        if funasrStreamCreated {
            Task { [weak self] in
                guard let self = self else { return }
                await FunASRService.shared.inputFinished()
                await FunASRService.shared.resetOnlineStream()
                await MainActor.run {
                    self.funasrStreamCreated = false
                }
            }
        }

        isRecording = false
        currentAmplitude = 0

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
    }

    // MARK: - 内部方法

    // MARK: - 音频分割（VAD 纯分割器，不参与录制决策）

    /// 始终追加音频到当前片段 buffer，使用 50ms 帧 + 采样计数做 VAD 切段
    /// - Parameter audio: 增益后的语音（写入 chunk buffer + 喂 FunASR）
    /// - Parameter rawAudio: 原始振幅音频（VAD 停顿检测用，不受增益干扰）
    private func appendAudioAndSegment(_ audio: [Float], rawAudio: [Float]) {
        let settings = SettingsManager.shared
        let frameSize = 800  // 50ms @ 16kHz
        let silenceThreshold = settings.silenceThreshold
        let pauseWindowSamples = Int(settings.pauseWindow * 16000)
        let maxChunkSamples = Int(settings.maxChunkDuration * 16000)

        let completeAudio = audio
        let completeRaw = rawAudio
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var frameStart = 0
            while frameStart < completeAudio.count {
                let frameEnd = min(frameStart + frameSize, completeAudio.count)
                var rawSum: Float = 0
                for i in frameStart..<frameEnd { rawSum += abs(completeRaw[i]) }
                let frameAmp = rawSum / Float(frameEnd - frameStart)
                let capturedFrameSize = frameEnd - frameStart

                self.currentChunkBuffer.append(contentsOf: completeAudio[frameStart..<frameEnd])

                if frameAmp > silenceThreshold {
                    if self.currentChunkStartTime == nil {
                        self.currentChunkStartTime = Date()
                    }
                    self.isListening = true
                    self.lastSpeechSampleIndex = self.currentChunkBuffer.count
                    self.silenceSampleCount = 0

                    if self.currentChunkBuffer.count >= maxChunkSamples {
                        // 向前找最近静音间隙（最多回退 5s），避免硬切在词语中间
                        let lookbackSamples = 5 * 16000
                        if self.lastPauseSampleIndex > 0 && self.currentChunkBuffer.count - self.lastPauseSampleIndex < lookbackSamples {
                            let overflow = Array(self.currentChunkBuffer.suffix(self.currentChunkBuffer.count - self.lastPauseSampleIndex))
                            self.currentChunkBuffer = Array(self.currentChunkBuffer.prefix(self.lastPauseSampleIndex))
                            self.cutCurrentChunk()
                            self.currentChunkBuffer.append(contentsOf: overflow)
                            self.currentChunkStartTime = Date()  // 续接段
                        } else {
                            self.cutCurrentChunk()
                        }
                    }
                } else {
                    if self.currentChunkStartTime != nil {
                        if self.silenceSampleCount == 0 {
                            self.lastPauseSampleIndex = self.currentChunkBuffer.count  // 记录语音→静音边界
                        }
                        self.silenceSampleCount += capturedFrameSize
                        if self.silenceSampleCount >= pauseWindowSamples {
                            self.cutCurrentChunk()
                        }
                    } else {
                        let maxSilent = 16000 * 3
                        if self.currentChunkBuffer.count > maxSilent {
                            self.currentChunkBuffer = Array(self.currentChunkBuffer.suffix(8000))
                        }
                    }
                }

                frameStart = frameEnd
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

        // 裁剪尾部静音：从末尾向回搜索，去掉接近零的采样点，防止尾随静音拉低平均能量
        var effectiveLength = currentChunkBuffer.count
        let settings = SettingsManager.shared
        let silenceFloor = settings.noiseGate // 之前写死 0.005，会导致远距离微小声音被裁断
        while effectiveLength > 0 && abs(currentChunkBuffer[effectiveLength - 1]) < silenceFloor {
            effectiveLength -= 1
        }
        guard effectiveLength > 0 else {
            // 全部是静音，直接丢弃
            currentChunkBuffer = []
            currentChunkStartTime = nil
            isListening = false
            return
        }
        let effectiveSamples = Array(currentChunkBuffer[0..<effectiveLength])

        // 检查片段是否有足够的语音能量（过滤纯噪声片段）
        let minChunkDuration: Double = 0.3  // 短于 0.3s 的片段视为噪声碎片，不予创建
        let effectiveDuration = Double(effectiveLength) / 16000.0
        guard effectiveDuration >= minChunkDuration else {
            AppLog.info("Discarded too-short noise segment duration=\(String(format: "%.3f", effectiveDuration))s")
            currentChunkBuffer = []
            currentChunkStartTime = nil
            isListening = false
            return
        }

        let avgEnergy = effectiveSamples.reduce(0) { $0 + abs($1) } / Float(effectiveLength)
        let minSpeechEnergy = settings.noiseGate * 0.5 // 平均能量低于此值视为纯噪声，之前写死 0.005 太高
        guard avgEnergy >= minSpeechEnergy else {
            AppLog.info("Discarded low-energy noise segment avgEnergy=\(String(format: "%.5f", avgEnergy))")
            currentChunkBuffer = []
            currentChunkStartTime = nil
            isListening = false
            return
        }
        
        let now = Date()
        let chunkStartTime = currentChunkStartTime?.timeIntervalSince(start) ?? max(0, now.timeIntervalSince(start) - Double(currentChunkBuffer.count) / 16000.0)
        let chunkEndTime = now.timeIntervalSince(start)
        
        let chunk = AudioChunk(
            id: "\(meetingId)_chunk_\(chunkCounter)",
            meetingId: meetingId,
            startTime: chunkStartTime,
            endTime: chunkEndTime,
            audioSamples: currentChunkBuffer,
            text: nil,
            isTranscribing: true,
            speakerLabel: nil
        )
        
        chunkCounter += 1

        // 使用 FunASR 流式累积文本
        let funasrText = funasrAccumulatedText.trimmingCharacters(in: .whitespaces)
        let capturedChunk = chunk
        var updatedChunk = capturedChunk
        let rawText = funasrText.isEmpty ? "" : funasrText

        if transcriptionEngine == .cloudModel,
           let (cloudModel, apiKey) = TranscriptionEngineCoordinator.shared.getActiveCloudTranscriptionModel() {
            // 云端大模型转写模式：先以 isTranscribing = true 加入列表
            updatedChunk.text = rawText
            updatedChunk.isTranscribing = true
            audioChunks.append(updatedChunk)

            let samplesToTranscribe = effectiveSamples
            Task { [weak self, capturedChunk, samplesToTranscribe, cloudModel, apiKey, rawText] in
                do {
                    // 获取已知参会人名单与上一句活跃说话人
                    let contacts = await self?.contactsProvider?() ?? []
                    let knownNames = contacts.map(\.name)
                    let priorSpeaker = await MainActor.run { () -> String? in
                        guard let self = self else { return nil }
                        return self.audioChunks.last(where: { $0.id != capturedChunk.id && !($0.speakerLabel?.isEmpty ?? true) })?.speakerLabel
                    }

                    let diarizedSentences = try await CloudTranscriptionService.shared.transcribeAndDiarizeSamples(
                        samples: samplesToTranscribe,
                        sampleRate: 16000,
                        contextSpeakers: knownNames,
                        priorSpeaker: priorSpeaker,
                        model: cloudModel,
                        apiKey: apiKey
                    )

                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        guard let idx = self.audioChunks.firstIndex(where: { $0.id == capturedChunk.id }) else { return }

                        if diarizedSentences.isEmpty {
                            let finalText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                            self.audioChunks[idx].text = finalText
                            self.audioChunks[idx].isTranscribing = false
                            return
                        }

                        if diarizedSentences.count == 1 {
                            let sentence = diarizedSentences[0]
                            let finalText = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            self.audioChunks[idx].text = finalText.isEmpty ? rawText : finalText
                            let speaker = sentence.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !speaker.isEmpty {
                                self.audioChunks[idx].speakerLabel = speaker
                                if let matched = contacts.first(where: { $0.name == speaker }) {
                                    self.onSpeakerMatched?(matched.id, matched.name)
                                } else if !self.discoveredSpeakerLabels.contains(speaker) {
                                    self.discoveredSpeakerLabels.insert(speaker)
                                    self.onNewSpeakerDiscovered?(speaker)
                                }
                            }
                            self.audioChunks[idx].isTranscribing = false
                        } else {
                            // 检测到抢话/多人快速轮替：拆分为多个独立 AudioChunk 行呈现
                            let baseChunk = self.audioChunks[idx]
                            self.audioChunks.remove(at: idx)

                            let totalDur = max(0.1, baseChunk.endTime - baseChunk.startTime)
                            let totalChars = max(1, diarizedSentences.reduce(0) { $0 + max(1, $1.text.count) })
                            var currentStart = baseChunk.startTime

                            for (i, sentence) in diarizedSentences.enumerated() {
                                let ratio = Double(max(1, sentence.text.count)) / Double(totalChars)
                                let dur = (i == diarizedSentences.count - 1) ? max(0.05, baseChunk.endTime - currentStart) : (totalDur * ratio)
                                let nextStart = currentStart + dur

                                let speaker = sentence.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
                                let subChunk = AudioChunk(
                                    id: "\(baseChunk.id)_\(i)",
                                    meetingId: baseChunk.meetingId,
                                    startTime: currentStart,
                                    endTime: nextStart,
                                    audioSamples: [],
                                    text: sentence.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                    isTranscribing: false,
                                    speakerLabel: speaker.isEmpty ? nil : speaker
                                )
                                self.audioChunks.append(subChunk)

                                if !speaker.isEmpty {
                                    if let matched = contacts.first(where: { $0.name == speaker }) {
                                        self.onSpeakerMatched?(matched.id, matched.name)
                                    } else if !self.discoveredSpeakerLabels.contains(speaker) {
                                        self.discoveredSpeakerLabels.insert(speaker)
                                        self.onNewSpeakerDiscovered?(speaker)
                                    }
                                }

                                currentStart = nextStart
                            }
                            self.audioChunks.sort { $0.startTime < $1.startTime }
                        }
                        self.mergeConsecutiveSameSpeakerChunks()
                        self.onVoiceprintLabelsUpdated?()
                    }
                } catch {
                    AppLog.warn("[LiveCloudASR] Cloud transcription failed: \(error.localizedDescription), falling back to local text")
                    let punctuated = await FunASRService.shared.addPunctuation(rawText)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if let idx = self.audioChunks.firstIndex(where: { $0.id == capturedChunk.id }) {
                            self.audioChunks[idx].text = punctuated.isEmpty ? rawText : punctuated
                            self.audioChunks[idx].isTranscribing = false
                        }
                    }
                }
            }
        } else {
            if transcriptionEngine == .cloudModel {
                AppLog.warn("[LiveCloudASR] Cloud model requested, but no audio model with API-KEY is ready. Falling back to local FunASR.")
            }
            // 本地 FunASR 模式：直接使用当前累积文本并异步添加标点
            updatedChunk.text = rawText
            updatedChunk.isTranscribing = false
            audioChunks.append(updatedChunk)

            Task { [weak self, capturedChunk, rawText] in
                let punctuated = await FunASRService.shared.addPunctuation(rawText)
                await MainActor.run { [weak self] in
                    if let idx = self?.audioChunks.firstIndex(where: { $0.id == capturedChunk.id }) {
                        self?.audioChunks[idx].text = punctuated.isEmpty ? rawText : punctuated
                    }
                }
            }
        }
        funasrAccumulatedText = ""  // 重置累积文本，准备下一段
        // 加锁清空伪流式缓冲区，防止 timer 在清空前触发推理导致跨段文本合并
        isInferring = true
        Task { [weak self] in
            guard let self else { return }
            await FunASRService.shared.resetOnlineStream()
            await MainActor.run { self.isInferring = false }
        }

        // 异步投递声纹提取（仅在本地引擎模式下使用本地 ERes2Net 批量提取）
        if transcriptionEngine == .localFunASR, !funasrText.isEmpty {
            Task { [weak self] in
                self?.enqueueChunkForVoiceprintBatch(updatedChunk)
            }
        }

        // 重置当前片段状态
        currentChunkBuffer = []
        currentChunkStartTime = nil
        lastSpeechSampleIndex = 0
        silenceSampleCount = 0
        lastPauseSampleIndex = 0
        lastChunkEndTime = max(lastChunkEndTime, currentChunkBuffer.isEmpty ? 0 : 0)
        isListening = false
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
        
        // 1. 调用混合链路进行精细分离（combinedSamples 即完整上下文，偏移 0）
        let hybridSegments = await DiarizationService.shared.extractHybridSegments(
            from: combinedSamples,
            allSamples: combinedSamples,
            globalOffset: 0.0
        )
        if hybridSegments.isEmpty {
            AppLog.warn("[AudioRecorder] Voiceprint batch hybrid extraction returned empty")
            return
        }
        
        let contacts = await contactsProvider?() ?? []
        // 记录本批次新识别到的联系人（用于自动加入参会人），格式: [contactId: contactName]
        var matchedContacts: [String: String] = [:]
        
        // 2. 将精细子片段分配标签
        var labeledSubSegments: [(start: Double, end: Double, label: String, embedding: [Float])] = []
        
        for sub in hybridSegments {
            let subDuration = sub.end - sub.start
            var assignedLabel: String

            // 短片段（<1.0s）：声纹置信度稍低，跳过联系人匹配，由增量聚类根据声纹或发言连续性平滑继承
            let shortSegment = subDuration < 1.0

            if !shortSegment, !contacts.isEmpty, let match = DiarizationService.matchSingleEmbedding(
                sub.embedding, against: contacts,
                threshold: SettingsManager.shared.liveMatchingThreshold
            ) {
                assignedLabel = match.contactName
                matchedContacts[match.contactId] = match.contactName
            } else {
                assignedLabel = await incrementalClustering.addEmbedding(
                    sub.embedding,
                    duration: subDuration,
                    startTime: sub.start,
                    endTime: sub.end
                )
                // 新发现的匿名说话人实时添加为参会人（短段返回 "?" 时不添加）
                if assignedLabel.hasPrefix("Speaker_"), !discoveredSpeakerLabels.contains(assignedLabel) {
                    discoveredSpeakerLabels.insert(assignedLabel)
                    onNewSpeakerDiscovered?(assignedLabel)
                }
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
        let finalUpdates = chunkUpdates
        await MainActor.run { [weak self] in
            guard let self = self else { return }
            for i in 0..<self.audioChunks.count {
                let chunkId = self.audioChunks[i].id
                if let update = finalUpdates[chunkId] {
                    self.audioChunks[i].speakerLabel = update.label
                    self.audioChunks[i].embedding = update.embedding
                }
            }
            self.mergeConsecutiveSameSpeakerChunks()
            self.onVoiceprintLabelsUpdated?()
        }
        
        for (contactId, contactName) in matchedContacts {
            onSpeakerMatched?(contactId, contactName) 
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
        let chunkDuration = chunk.endTime - chunk.startTime
        AppLog.info("Voiceprint matching: \(contacts.count) candidates, chunk duration \(String(format: "%.1f", chunkDuration))s")

        guard let embedding = await DiarizationService.shared.extractEmbedding(from: chunk.audioSamples) else {
            AppLog.info("Voiceprint matching: embedding extraction failed")
            return
        }

        // 始终保存 embedding 到 chunk（供离线分析回退复用）
        await MainActor.run {
            guard let idx = self.audioChunks.firstIndex(where: { $0.id == chunk.id }) else { return }
            self.audioChunks[idx].embedding = embedding
        }

        // 短片段（<1.6s）：声纹不可靠，跳过联系人匹配，仅尝试增量聚类继承已有标签
        // eres2net 在 <1.6s 时依赖上下文填充，嵌入中混合了相邻说话人音频
        let shortSegment = chunkDuration < 1.6

        if !shortSegment,
           let match = DiarizationService.matchSingleEmbedding(
               embedding, against: contacts,
               threshold: SettingsManager.shared.liveMatchingThreshold
           ) {
            await MainActor.run {
                guard let idx = self.audioChunks.firstIndex(where: { $0.id == chunk.id }) else { return }
                self.audioChunks[idx].speakerLabel = match.contactName
                self.mergeConsecutiveSameSpeakerChunks()
                onVoiceprintLabelsUpdated?()
            }
            AppLog.info("Voiceprint matched: \(match.contactName) (score=\(String(format: "%.3f", match.score)))")
            onSpeakerMatched?(match.contactId, match.contactName)
        } else {
            // 未匹配已知联系人（或短片段跳过匹配）→ 增量聚类自动关联同会议未知说话人
            let label = await incrementalClustering.addEmbedding(embedding, duration: chunkDuration)
            AppLog.info("Voiceprint clustering: assigned \(label) (threshold=\(SettingsManager.shared.liveMatchingThreshold))")
            await MainActor.run {
                guard let idx = self.audioChunks.firstIndex(where: { $0.id == chunk.id }) else { return }
                self.audioChunks[idx].speakerLabel = label
                self.mergeConsecutiveSameSpeakerChunks()
                onVoiceprintLabelsUpdated?()
            }
        }
    }

    /// 在给已完成语音片段打上发言人标签后，自动合并相邻的同发言人片段，避免界面过于碎片化
    @MainActor
    private func mergeConsecutiveSameSpeakerChunks() {
        guard self.audioChunks.count > 1 else { return }
        var merged: [AudioChunk] = []
        
        for chunk in self.audioChunks {
            if var last = merged.last,
               last.speakerLabel == chunk.speakerLabel,
               last.speakerLabel != nil,
               !last.isTranscribing, !chunk.isTranscribing {
                
                // 如果是同一个说话人，且相隔不超过 0 秒，则进行合并（已禁用自动合并）
                if chunk.startTime - last.endTime < 0 {
                    last.endTime = chunk.endTime
                    last.audioSamples.append(contentsOf: chunk.audioSamples)
                    if let t1 = last.text, let t2 = chunk.text {
                        last.text = t1 + (t2.isEmpty ? "" : " " + t2)
                    } else {
                        last.text = last.text ?? chunk.text
                    }
                    merged[merged.count - 1] = last
                    continue
                }
            }
            merged.append(chunk)
        }
        self.audioChunks = merged
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
            // 有语音：计算将峰值推到目标所需的增益
            let neededGain = targetPeak / peak
            let rawGain = max(baseGain, neededGain)
            // 确保增益后峰值不超过 0.95，避免硬限幅导致谐波失真（会降低 Whisper 识别率）
            let safeGainLimit: Float = 0.95 / max(peak, 0.001)
            gain = min(rawGain, safeGainLimit, maxGain)
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

    // MARK: - 用户手动编辑

    /// 更新指定 AudioChunk 的文本（用户手动编辑）
    func updateChunkText(chunkId: String, newText: String) {
        if let idx = audioChunks.firstIndex(where: { $0.id == chunkId }) {
            audioChunks[idx].text = newText
            audioChunks[idx].isManualEdit = true
        }
    }

    /// 更新指定 AudioChunk 的发言人标签（用户手动分配）
    func updateChunkSpeaker(chunkId: String, newSpeaker: String) {
        if let idx = audioChunks.firstIndex(where: { $0.id == chunkId }) {
            audioChunks[idx].speakerLabel = newSpeaker
            audioChunks[idx].isManualEdit = true
        }
    }

    /// 批量重命名所有 AudioChunk 中匹配 oldName 的发言人标签
    func batchRenameChunkSpeaker(oldName: String, newName: String) {
        for i in 0..<audioChunks.count {
            if audioChunks[i].speakerLabel == oldName {
                audioChunks[i].speakerLabel = newName
                audioChunks[i].isManualEdit = true
            }
        }
    }
}

// MARK: - 错误类型

enum RecorderError: LocalizedError {
    case microphoneAccessDenied
    case audioResampleFailed
    case audioResampleFailedWithError(Error)

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied: return loc("mic_permission_denied")
        case .audioResampleFailed: return loc("audio_resample_failed")
        case .audioResampleFailedWithError(let err): return "\(loc("audio_resample_failed")): \(err.localizedDescription)"
        }
    }
}
