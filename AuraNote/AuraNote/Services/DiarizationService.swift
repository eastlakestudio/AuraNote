import Foundation
import AVFoundation

// MARK: - Data Types (unchanged public API)

struct DiarizedSegment {
    let speakerId: String
    let startTime: Double
    let endTime: Double
}

struct DiarizationOutput {
    let segments: [DiarizedSegment]
    /// 各说话人的平均声纹向量（eres2net 模型提取），用于声纹匹配
    let embeddings: [String: [Float]]
}

// MARK: - Diarization Service (sherpa-onnx)

actor DiarizationService {
    static let shared = DiarizationService()

    // MARK: - Model Paths

    private var modelsDir: String {
        guard let resourcePath = Bundle.main.resourcePath else { return "" }
        return resourcePath + "/sherpa-onnx-models"
    }

    private func segmentationModelPath() -> String {
        // INT8 量化版（1.5MB），Apple Silicon AMX 协处理器加速，比 FP32 版快 2-3 倍
        return modelsDir + "/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx"
    }

    private func embeddingModelPath() -> String {
        return modelsDir + "/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
    }

    // MARK: - Diarizer

    private var diarizer: SherpaOnnxDiarizer?
    private var cachedThreshold: Double?
    private var embeddingExtractor: SherpaOnnxEmbeddingExtractor?

    private func getDiarizer() throws -> SherpaOnnxDiarizer {
        let threshold = SettingsManager.shared.clusteringThreshold

        if let d = diarizer, cachedThreshold == threshold {
            return d
        }

        let segPath = segmentationModelPath()
        let embPath = embeddingModelPath()

        guard FileManager.default.fileExists(atPath: segPath) else {
            throw SherpaError.modelNotFound("分割模型: \(segPath)")
        }
        guard FileManager.default.fileExists(atPath: embPath) else {
            throw SherpaError.modelNotFound("声纹模型: \(embPath)")
        }

        var config = SherpaDiarizationConfig()
        config.segmentationModel = segPath
        config.embeddingModel = embPath
        config.clustering.threshold = Float(threshold)
        config.clustering.numClusters = -1  // 自动判断人数
        config.minDurationOn = SettingsManager.shared.minDurationOn
        config.minDurationOff = SettingsManager.shared.minDurationOff
        config.numThreads = 4  // 无风扇设备上线程过多导致热降频，4 线程是甜点

        let d = SherpaOnnxDiarizer()
        try d.create(config: config)

        self.diarizer = d
        self.cachedThreshold = threshold

        AppLog.info("[DiarService] sherpa-onnx diarizer created: threshold=\(threshold) autoSpeakers")
        return d
    }

    private func getEmbeddingExtractor() throws -> SherpaOnnxEmbeddingExtractor {
        if let ex = embeddingExtractor { return ex }

        let embPath = embeddingModelPath()
        guard FileManager.default.fileExists(atPath: embPath) else {
            throw SherpaError.modelNotFound("声纹模型: \(embPath)")
        }

        let ex = SherpaOnnxEmbeddingExtractor()
        try ex.create(modelPath: embPath, numThreads: 1)
        self.embeddingExtractor = ex
        AppLog.info("[DiarService] sherpa-onnx embedding extractor created, dim=\(ex.dimension)")
        return ex
    }

    // MARK: - Audio Loading

    func loadAudioSamples(_ url: URL) async throws -> [Float] {
        let asset = AVAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw SherpaError.audioLoadFailed("无音频轨道: \(url.lastPathComponent)")
        }

        let descs = try await track.load(.formatDescriptions)
        guard let desc = descs.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            throw SherpaError.audioLoadFailed("无法获取音频格式")
        }

        let originalRate = Int(basic.mSampleRate)
        let reader = try AVAssetReader(asset: asset)

        // 始终输出 16kHz float32 mono
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: originalRate
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        var allSamples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            if let data = dataPointer {
                let floatPtr = data.withMemoryRebound(to: Float.self, capacity: length / 4) { $0 }
                let buf = UnsafeBufferPointer(start: floatPtr, count: length / 4)
                allSamples.append(contentsOf: buf)
            }
        }

        guard reader.status == .completed else {
            throw SherpaError.audioLoadFailed("读取失败: \(reader.status.rawValue)")
        }

        // 重采样到 16kHz（如需要）
        if originalRate != 16000 {
            return try resample(allSamples, from: originalRate, to: 16000)
        }
        return allSamples
    }

    private func resample(_ samples: [Float], from srcRate: Int, to dstRate: Int) throws -> [Float] {
        guard srcRate != dstRate else { return samples }
        let ratio = Double(dstRate) / Double(srcRate)
        let outCount = Int(Double(samples.count) * ratio)
        var result = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcIdx = Double(i) / ratio
            let i0 = Int(srcIdx)
            let i1 = min(i0 + 1, samples.count - 1)
            let frac = Float(srcIdx - Double(i0))
            result[i] = samples[i0] * (1 - frac) + samples[i1] * frac
        }
        return result
    }

    // MARK: - Public API

    /// 旧版管线（sherpa-onnx 内置聚类，保留作为回退）
    func diarize(audioURL: URL) async throws -> [DiarizedSegment] {
        let output = try await diarizeWithEmbeddings(audioURL: audioURL)
        return output.segments
    }

    /// 旧版声纹分离（sherpa-onnx 内置聚类），保留作为回退方案
    func diarizeWithEmbeddings(audioURL: URL, onProgress: ((Float) -> Void)? = nil) async throws -> DiarizationOutput {
        let startTime = Date()
        AppLog.info("[DiarService] sherpa-onnx diarization start: audio=\(audioURL.lastPathComponent)")

        let d = try getDiarizer()
        let samples = try await loadAudioSamples(audioURL)
        let audioDuration = Double(samples.count) / 16000.0
        AppLog.info("[DiarService] audio loaded: \(samples.count) samples @ 16kHz, duration=\(String(format: "%.1f", audioDuration))s")

        var lastLoggedProgress: Float = 0
        let result = try d.process(samples: samples) { progress in
            onProgress?(progress)
            // 每 10% 打一次进度日志
            let pct = Int(progress * 100)
            let lastPct = Int(lastLoggedProgress * 100)
            if pct - lastPct >= 10 || progress >= 1.0 {
                lastLoggedProgress = progress
                let elapsed = Date().timeIntervalSince(startTime)
                AppLog.info("[DiarService] diarization progress: \(pct)% (elapsed: \(String(format: "%.1f", elapsed))s)")
            }
        }

        // Convert to DiarizedSegment
        let segments: [DiarizedSegment] = result.segments.map { seg in
            DiarizedSegment(
                speakerId: "Speaker_\(seg.speaker)",
                startTime: Double(seg.start),
                endTime: Double(seg.end)
            )
        }

        let uniqueSpeakers = Set(segments.map(\.speakerId)).sorted()
        let processElapsed = Date().timeIntervalSince(startTime)
        AppLog.info("[DiarService] result: \(uniqueSpeakers.count) speakers, \(segments.count) segments (elapsed: \(String(format: "%.1f", processElapsed))s)")
        for spk in uniqueSpeakers {
            let count = segments.filter { $0.speakerId == spk }.count
            let dur = segments.filter { $0.speakerId == spk }.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
            AppLog.info("[DiarService]   \(spk): \(count) segments, \(String(format: "%.1f", dur))s total")
        }

        // Extract embeddings for each speaker (for offline matching)
        // 只取每个说话人的代表性片段（最多 30 秒），避免拼接全部音频
        var rawEmbeddings: [String: [Float]] = [:]
        if !uniqueSpeakers.isEmpty {
            let ex = try? getEmbeddingExtractor()
            if let ex = ex {
                let maxSamplesPerSpeaker = 30 * 16000  // 最多 30 秒
                for speakerId in uniqueSpeakers {
                    var speakerSamples: [Float] = []
                    speakerSamples.reserveCapacity(maxSamplesPerSpeaker)
                    for seg in segments where seg.speakerId == speakerId {
                        if speakerSamples.count >= maxSamplesPerSpeaker { break }
                        let startIdx = Int(seg.startTime * 16000)
                        let endIdx = min(Int(seg.endTime * 16000), samples.count)
                        guard startIdx < endIdx else { continue }
                        let remaining = maxSamplesPerSpeaker - speakerSamples.count
                        let take = min(endIdx - startIdx, remaining)
                        speakerSamples.append(contentsOf: samples[startIdx..<(startIdx + take)])
                    }
                    if !speakerSamples.isEmpty {
                        do {
                            let emb = try ex.extractEmbedding(samples: speakerSamples)
                            rawEmbeddings[speakerId] = emb
                        } catch {
                            AppLog.warn("[DiarService] embedding extraction failed for \(speakerId): \(error)")
                        }
                    }
                }
                AppLog.info("[DiarService] voiceprint extraction complete: \(rawEmbeddings.count) speakers, dim=\(ex.dimension)")
            }
        }

        return DiarizationOutput(
            segments: segments,
            embeddings: rawEmbeddings
        )
    }

    /// 离线语音间隙分段 + 增量聚类（三阶段流水线，与实时录音共用同一聚类算法）
    /// - 阶段 1: VAD 获取语音段边界（pyannote 高精度 或 能量快速模式）
    /// - 阶段 2+3: 逐段提取声纹并立即增量聚类（流式），每段完成即回调
    /// - Parameter fastVAD: true 时跳过 pyannote，使用能量 VAD 瞬时切段（速度快 100+ 倍，精度稍低）
    func diarizeSegmented(
        audioURL: URL,
        fastVAD: Bool = false,
        onVADComplete: @escaping (_ segmentCount: Int) -> Void = { _ in },
        onEmbeddingProgress: @escaping (_ done: Int, _ total: Int) -> Void = { _, _ in },
        onIncrementalResult: @escaping (_ segments: [DiarizedSegment], _ embeddings: [String: [Float]]) async -> Void = { _, _ in },
        onClusteringComplete: @escaping (_ speakerCount: Int) -> Void = { _ in }
    ) async throws -> DiarizationOutput {
        let startTime = Date()
        AppLog.info("[DiarService] segmented diarization start: audio=\(audioURL.lastPathComponent) fastVAD=\(fastVAD)")

        let samples = try await loadAudioSamples(audioURL)
        let audioDuration = Double(samples.count) / 16000.0
        AppLog.info("[DiarService] audio loaded: \(samples.count) samples, duration=\(String(format: "%.1f", audioDuration))s")

        // ═══ 阶段 1: VAD 语音分段 ═══
        let vadSegments: [(start: Double, end: Double)]
        if fastVAD {
            // 快速模式：能量 VAD，瞬时完成（与实时录音共用同一阈值体系）
            AppLog.info("[DiarService] Phase 1: energy VAD (fast mode)...")
            let vadStartTime = Date()
            vadSegments = energyVADSegments(samples: samples)
            let vadElapsed = Date().timeIntervalSince(vadStartTime)
            AppLog.info("[DiarService] Phase 1 (fast) complete: \(vadSegments.count) speech segments (elapsed: \(String(format: "%.3f", vadElapsed))s)")
        } else {
            // 高精度模式：sherpa-onnx pyannote VAD
            let d = try getDiarizer()
            AppLog.info("[DiarService] Phase 1: VAD segmentation via sherpa-onnx pyannote...")
            let vadStartTime = Date()
            var lastLoggedVadPct = -1
            var lastHeartbeatTime = vadStartTime
            let result = try d.process(samples: samples) { progress in
                let pct = Int(progress * 100)
                let now = Date()
                if pct != lastLoggedVadPct {
                    lastLoggedVadPct = pct
                    let elapsed = now.timeIntervalSince(vadStartTime)
                    AppLog.info("[DiarService] VAD progress: \(pct)% (elapsed: \(String(format: "%.1f", elapsed))s)")
                } else if now.timeIntervalSince(lastHeartbeatTime) >= 30 {
                    lastHeartbeatTime = now
                    let elapsed = now.timeIntervalSince(vadStartTime)
                    AppLog.info("[DiarService] VAD still running at \(pct)% (elapsed: \(String(format: "%.1f", elapsed))s)")
                }
            }
            let vadElapsed = Date().timeIntervalSince(vadStartTime)
            vadSegments = result.segments.map { seg in
                (start: Double(seg.start), end: Double(seg.end))
            }
            AppLog.info("[DiarService] Phase 1 complete: \(vadSegments.count) speech segments (elapsed: \(String(format: "%.1f", vadElapsed))s)")
        }
        onVADComplete(vadSegments.count)

        guard !vadSegments.isEmpty else {
            AppLog.warn("[DiarService] VAD returned 0 segments — returning empty result")
            return DiarizationOutput(segments: [], embeddings: [:])
        }

        // ═══ 阶段 2+3: 逐段声纹提取 + 即时增量聚类（流式） ═══
        AppLog.info("[DiarService] Phase 2+3: streaming extraction + incremental clustering...")
        let embStartTime = Date()
        let ex = try getEmbeddingExtractor()
        let distThreshold = SettingsManager.shared.incrementalClusteringDistance
        let clustering = IncrementalSpeakerClustering(mergeDistanceThreshold: distThreshold)
        var outputSegments: [DiarizedSegment] = []
        var speakerEmbeddingLists: [String: [[Float]]] = [:]
        var skippedCount = 0

        for (i, seg) in vadSegments.enumerated() {
            let startIdx = Int(seg.start * 16000)
            let endIdx = min(Int(seg.end * 16000), samples.count)
            guard startIdx < endIdx else {
                skippedCount += 1
                onEmbeddingProgress(i + 1, vadSegments.count)
                continue
            }
            let segSamples = Array(samples[startIdx..<endIdx])
            let segDuration = Double(segSamples.count) / 16000.0

            // 跳过过短片段（< 0.3s，声纹不可靠）
            guard segDuration >= 0.3 else {
                skippedCount += 1
                onEmbeddingProgress(i + 1, vadSegments.count)
                continue
            }

            do {
                let emb = try ex.extractEmbedding(samples: segSamples, sampleRate: 16000)
                // 即时聚类：每提取一个 embedding 就归入聚类，无需等全部完成
                let label = await clustering.addEmbedding(emb)
                speakerEmbeddingLists[label, default: []].append(emb)

                outputSegments.append(DiarizedSegment(
                    speakerId: label,
                    startTime: seg.start,
                    endTime: seg.end
                ))

                // 构建当前各说话人的平均声纹（供声纹匹配）
                var incrementalEmbs: [String: [Float]] = [:]
                for (spk, embs) in speakerEmbeddingLists where !embs.isEmpty {
                    let dim = embs[0].count
                    var avg = [Float](repeating: 0, count: dim)
                    for e in embs {
                        for j in 0..<dim { avg[j] += e[j] }
                    }
                    for j in 0..<dim { avg[j] /= Float(embs.count) }
                    incrementalEmbs[spk] = avg
                }

                // 流式回调：每处理完一段即通知外部，缩短标签出现延迟
                await onIncrementalResult(outputSegments, incrementalEmbs)
            } catch {
                AppLog.warn("[DiarService] embedding extraction failed for segment \(i) (dur=\(String(format: "%.1f", segDuration))s): \(error)")
                skippedCount += 1
            }
            onEmbeddingProgress(i + 1, vadSegments.count)
        }
        let embElapsed = Date().timeIntervalSince(embStartTime)
        let speakerCount = Set(outputSegments.map(\.speakerId)).count
        AppLog.info("[DiarService] Phase 2+3 complete: \(speakerCount) speakers, \(outputSegments.count) segments, \(skippedCount) skipped (elapsed: \(String(format: "%.1f", embElapsed))s)")
        for spk in Set(outputSegments.map(\.speakerId)).sorted() {
            let count = outputSegments.filter { $0.speakerId == spk }.count
            AppLog.info("[DiarService]   \(spk): \(count) segments")
        }
        onClusteringComplete(speakerCount)

        // 每个说话人的平均声纹（供离线声纹匹配）
        var rawEmbeddings: [String: [Float]] = [:]
        for (speaker, embs) in speakerEmbeddingLists where !embs.isEmpty {
            let dim = embs[0].count
            var avg = [Float](repeating: 0, count: dim)
            for emb in embs {
                for j in 0..<dim { avg[j] += emb[j] }
            }
            for j in 0..<dim { avg[j] /= Float(embs.count) }
            rawEmbeddings[speaker] = avg
        }

        let totalElapsed = Date().timeIntervalSince(startTime)
        AppLog.info("[DiarService] segmented diarization complete: \(speakerCount) speakers, \(outputSegments.count) segments (total: \(String(format: "%.1f", totalElapsed))s)")
        for spk in Set(outputSegments.map(\.speakerId)).sorted() {
            let count = outputSegments.filter { $0.speakerId == spk }.count
            let dur = outputSegments.filter { $0.speakerId == spk }.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
            AppLog.info("[DiarService]   \(spk): \(count) segments, \(String(format: "%.1f", dur))s total")
        }

        return DiarizationOutput(
            segments: outputSegments,
            embeddings: rawEmbeddings
        )
    }

    // MARK: - Energy VAD (Fast Mode)

    /// 基于振幅的能量 VAD 切段，与实时录音共用同一阈值体系。
    /// 扫描全部采样，按 silenceThreshold + pauseWindow 检测语音边界。
    /// 时间复杂度 O(n)，11 分钟音频约 0.01 秒完成。
    private func energyVADSegments(samples: [Float]) -> [(start: Double, end: Double)] {
        let s = SettingsManager.shared
        let silenceThreshold: Float = s.silenceThreshold      // 0.02
        let pauseWindow: Double = s.pauseWindow                 // 1.0s
        let minSpeechOnset: Double = 0.3  // 最短有效语音段（秒），过滤瞬时噪声
        let maxChunkDuration: Double = s.maxChunkDuration       // 8.0s
        let sampleRate = 16000
        let frameSize = 256  // ~16ms per frame

        var segments: [(start: Double, end: Double)] = []
        var inSpeech = false
        var speechStartSample = 0
        var lastSpeechSample = 0
        var silenceSampleCount = 0

        var i = 0
        while i < samples.count {
            let end = min(i + frameSize, samples.count)
            var sum: Float = 0
            for j in i..<end {
                sum += abs(samples[j])
            }
            let amplitude = sum / Float(end - i)

            if amplitude > silenceThreshold {
                if !inSpeech {
                    inSpeech = true
                    speechStartSample = i
                }
                lastSpeechSample = end
                silenceSampleCount = 0

                // 强制切分超过最大时长的语音段
                let currentDuration = Double(end - speechStartSample) / Double(sampleRate)
                if currentDuration >= maxChunkDuration {
                    let segStart = Double(speechStartSample) / Double(sampleRate)
                    let segEnd = Double(end) / Double(sampleRate)
                    let dur = segEnd - segStart
                    if dur >= minSpeechOnset {
                        segments.append((start: segStart, end: segEnd))
                    }
                    speechStartSample = end
                }
            } else {
                if inSpeech {
                    silenceSampleCount += (end - i)
                    let silenceDuration = Double(silenceSampleCount) / Double(sampleRate)
                    if silenceDuration >= pauseWindow {
                        // 停顿足够长，切割当前段
                        let segStart = Double(speechStartSample) / Double(sampleRate)
                        let segEnd = Double(lastSpeechSample) / Double(sampleRate)
                        let dur = segEnd - segStart
                        if dur >= minSpeechOnset {
                            segments.append((start: segStart, end: segEnd))
                        }
                        inSpeech = false
                        silenceSampleCount = 0
                    }
                }
            }
            i = end
        }

        // 处理最后未完成段
        if inSpeech {
            let segStart = Double(speechStartSample) / Double(sampleRate)
            let segEnd = Double(lastSpeechSample) / Double(sampleRate)
            let dur = segEnd - segStart
            if dur >= minSpeechOnset {
                segments.append((start: segStart, end: segEnd))
            }
        }

        return segments
    }

    // MARK: - Whisper Segment-Based Diarization
    
    /// 使用外部分段边界（如 Whisper 转写段）进行声纹提取和增量聚类。
    /// 跳过 VAD，直接基于已有段边界提取声纹——边界天然对齐转写结果，无需时间轴对齐。
    /// - Parameters:
    ///   - samples: 预加载的 16kHz 音频采样（避免重复加载）
    ///   - segmentBoundaries: 分段起止时间 (start, end)，单位为秒
    func diarizeFromSegments(
        samples: [Float],
        segmentBoundaries: [(Double, Double)],
        onEmbeddingProgress: @escaping (_ done: Int, _ total: Int) -> Void = { _, _ in },
        onIncrementalResult: @escaping (_ segments: [DiarizedSegment], _ embeddings: [String: [Float]]) async -> Void = { _, _ in },
        onClusteringComplete: @escaping (_ speakerCount: Int) -> Void = { _ in }
    ) async -> DiarizationOutput {
        let startTime = Date()
        AppLog.info("[DiarService] diarize from \(segmentBoundaries.count) external segments (no VAD)")
    
        guard !segmentBoundaries.isEmpty else {
            return DiarizationOutput(segments: [], embeddings: [:])
        }
    
        // Phase 2+3: per-segment embedding + streaming clustering
        let ex: SherpaOnnxEmbeddingExtractor
        do {
            ex = try getEmbeddingExtractor()
        } catch {
            AppLog.error("[DiarService] failed to create embedding extractor: \(error)")
            return DiarizationOutput(segments: [], embeddings: [:])
        }
    
        return await processSegments(
            samples: samples,
            boundarySource: .array(segmentBoundaries),
            extractor: ex,
            onIncrementalResult: onIncrementalResult,
            onClusteringComplete: onClusteringComplete,
            startTime: startTime
        )
    }
    
    /// 流式版本：从 AsyncStream 消费 Whisper 分段边界，边到达边提取声纹并聚类。
    /// 与 Whisper 转写并行运行——Whisper 每产出一段，声纹立即处理一段，标签随转写进度逐段出现。
    /// - Parameters:
    ///   - samples: 预加载的 16kHz 音频采样
    ///   - boundaryStream: Whisper 实时产出的分段边界流
    func diarizeFromStream(
        samples: [Float],
        boundaryStream: AsyncStream<(Double, Double)>,
        onIncrementalResult: @escaping (_ segments: [DiarizedSegment], _ embeddings: [String: [Float]]) async -> Void,
        onClusteringComplete: @escaping (_ speakerCount: Int) -> Void = { _ in }
    ) async -> DiarizationOutput {
        let startTime = Date()
        AppLog.info("[DiarService] diarize from stream started (parallel with Whisper)")
    
        let ex: SherpaOnnxEmbeddingExtractor
        do {
            ex = try getEmbeddingExtractor()
        } catch {
            AppLog.error("[DiarService] failed to create embedding extractor: \(error)")
            // 消费掉 stream 避免 producer 阻塞
            for await _ in boundaryStream {}
            return DiarizationOutput(segments: [], embeddings: [:])
        }
    
        return await processSegments(
            samples: samples,
            boundarySource: .stream(boundaryStream),
            extractor: ex,
            onIncrementalResult: onIncrementalResult,
            onClusteringComplete: onClusteringComplete,
            startTime: startTime
        )
    }
    
    // MARK: - Shared Processing Core
    
    private enum BoundarySource {
        case array([(Double, Double)])
        case stream(AsyncStream<(Double, Double)>)
    }
    
    /// 核心处理循环：逐段提取声纹 + 增量聚类，支持数组和流式两种输入源
    private func processSegments(
        samples: [Float],
        boundarySource: BoundarySource,
        extractor: SherpaOnnxEmbeddingExtractor,
        onIncrementalResult: @escaping (_ segments: [DiarizedSegment], _ embeddings: [String: [Float]]) async -> Void,
        onClusteringComplete: @escaping (_ speakerCount: Int) -> Void,
        startTime: Date
    ) async -> DiarizationOutput {
        let distThreshold = SettingsManager.shared.incrementalClusteringDistance
        let clustering = IncrementalSpeakerClustering(mergeDistanceThreshold: distThreshold)
        var outputSegments: [DiarizedSegment] = []
        var speakerEmbeddingLists: [String: [[Float]]] = [:]
        var processedCount = 0
        var skippedCount = 0
    
        /// 处理单个边界
        func processOne(_ segStart: Double, _ segEnd: Double) async {
            let startIdx = Int(segStart * 16000)
            let endIdx = min(Int(segEnd * 16000), samples.count)
            guard startIdx < endIdx else {
                skippedCount += 1
                return
            }
            let segSamples = Array(samples[startIdx..<endIdx])
            let segDuration = Double(segSamples.count) / 16000.0
            guard segDuration >= 0.3 else {
                skippedCount += 1
                return
            }
            do {
                let emb = try extractor.extractEmbedding(samples: segSamples, sampleRate: 16000)
                let label = await clustering.addEmbedding(emb)
                speakerEmbeddingLists[label, default: []].append(emb)
    
                outputSegments.append(DiarizedSegment(
                    speakerId: label,
                    startTime: segStart,
                    endTime: segEnd
                ))
    
                // 计算平均声纹
                var incrementalEmbs: [String: [Float]] = [:]
                for (spk, embs) in speakerEmbeddingLists where !embs.isEmpty {
                    let dim = embs[0].count
                    var avg = [Float](repeating: 0, count: dim)
                    for e in embs {
                        for j in 0..<dim { avg[j] += e[j] }
                    }
                    for j in 0..<dim { avg[j] /= Float(embs.count) }
                    incrementalEmbs[spk] = avg
                }
                await onIncrementalResult(outputSegments, incrementalEmbs)
                processedCount += 1
            } catch {
                AppLog.warn("[DiarService] embedding extraction failed for segment \(processedCount): \(error)")
                skippedCount += 1
            }
        }
    
        switch boundarySource {
        case .array(let boundaries):
            for boundary in boundaries {
                await processOne(boundary.0, boundary.1)
            }
        case .stream(let stream):
            for await boundary in stream {
                await processOne(boundary.0, boundary.1)
            }
        }

        // 聚类级合并：全部段处理完后，用充足数据量的簇质心互比，避免小簇误合并
        let remap = await clustering.mergeSimilarClusters()
        if !remap.isEmpty {
            outputSegments = outputSegments.map { seg in
                if let newLabel = remap[seg.speakerId] {
                    return DiarizedSegment(speakerId: newLabel, startTime: seg.startTime, endTime: seg.endTime)
                }
                return seg
            }
            var remappedLists: [String: [[Float]]] = [:]
            for (oldLabel, embs) in speakerEmbeddingLists {
                let newLabel = remap[oldLabel] ?? oldLabel
                remappedLists[newLabel, default: []].append(contentsOf: embs)
            }
            speakerEmbeddingLists = remappedLists
        }

        let speakerCount = Set(outputSegments.map(\.speakerId)).count
        let label = if case .stream = boundarySource { "stream" } else { "segments" }
        AppLog.info("[DiarService] diarize from \(label) complete: \(speakerCount) speakers, \(outputSegments.count) segments, \(skippedCount) skipped (elapsed: \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s)")
        onClusteringComplete(speakerCount)
    
        var rawEmbeddings: [String: [Float]] = [:]
        for (speaker, embs) in speakerEmbeddingLists where !embs.isEmpty {
            let dim = embs[0].count
            var avg = [Float](repeating: 0, count: dim)
            for emb in embs {
                for j in 0..<dim { avg[j] += emb[j] }
            }
            for j in 0..<dim { avg[j] /= Float(embs.count) }
            rawEmbeddings[speaker] = avg
        }
    
        return DiarizationOutput(segments: outputSegments, embeddings: rawEmbeddings)
    }

    /// 便捷重载：从 URL 加载音频后调用上述方法
    func diarizeFromSegments(
        audioURL: URL,
        segmentBoundaries: [(Double, Double)],
        onEmbeddingProgress: @escaping (_ done: Int, _ total: Int) -> Void = { _, _ in },
        onIncrementalResult: @escaping (_ segments: [DiarizedSegment], _ embeddings: [String: [Float]]) async -> Void = { _, _ in },
        onClusteringComplete: @escaping (_ speakerCount: Int) -> Void = { _ in }
    ) async throws -> DiarizationOutput {
        let samples = try await loadAudioSamples(audioURL)
        return await diarizeFromSegments(
            samples: samples,
            segmentBoundaries: segmentBoundaries,
            onEmbeddingProgress: onEmbeddingProgress,
            onIncrementalResult: onIncrementalResult,
            onClusteringComplete: onClusteringComplete
        )
    }

    /// 从原始音频采样中提取说话人声纹向量（用于实时片段级匹配）
    func extractEmbedding(from audioSamples: [Float]) async -> [Float]? {
        guard !audioSamples.isEmpty else { return nil }
        do {
            let ex = try getEmbeddingExtractor()
            let emb = try ex.extractEmbedding(samples: audioSamples)
            return emb
        } catch {
            AppLog.warn("[DiarService] real-time embedding extraction failed: \(error)")
            return nil
        }
    }

    // MARK: - Matching (unchanged)

    /// 单条声纹匹配最近联系人
    static func matchSingleEmbedding(
        _ embedding: [Float],
        against contacts: [(id: String, name: String, embedding: [Float])],
        threshold: Float = -1
    ) -> (contactId: String, contactName: String, score: Float)? {
        let effectiveThreshold = threshold < 0 ? SettingsManager.shared.matchingThreshold : threshold
        var bestScore: Float = -1
        var bestContact: (id: String, name: String)?
        for contact in contacts {
            let score = cosineSimilarity(embedding, contact.embedding)
            if score > bestScore { bestScore = score; bestContact = (contact.id, contact.name) }
        }
        if let contact = bestContact, bestScore >= effectiveThreshold {
            return (contact.id, contact.name, bestScore)
        }
        return nil
    }

    static func matchSpeakers(
        newEmbeddings: [String: [Float]],
        knownContacts: [(id: String, name: String, embedding: [Float])],
        threshold: Float = -1
    ) -> [String: (contactId: String, contactName: String, score: Float)] {
        let effectiveThreshold = threshold < 0 ? SettingsManager.shared.matchingThreshold : threshold
        var candidates: [(speakerId: String, contactId: String, contactName: String, score: Float)] = []
        for (speakerId, newEmb) in newEmbeddings {
            for contact in knownContacts {
                let score = cosineSimilarity(newEmb, contact.embedding)
                if score >= effectiveThreshold {
                    candidates.append((speakerId, contact.id, contact.name, score))
                }
            }
        }
        candidates.sort { $0.score > $1.score }
        var assignedSpeakers = Set<String>()
        var assignedContacts = Set<String>()
        var matches: [String: (contactId: String, contactName: String, score: Float)] = [:]
        for c in candidates {
            guard !assignedSpeakers.contains(c.speakerId),
                  !assignedContacts.contains(c.contactId) else { continue }
            assignedSpeakers.insert(c.speakerId)
            assignedContacts.insert(c.contactId)
            matches[c.speakerId] = (contactId: c.contactId, contactName: c.contactName, score: c.score)
        }
        return matches
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in 0..<a.count { dot += a[i]*b[i]; magA += a[i]*a[i]; magB += b[i]*b[i] }
        let den = sqrt(magA)*sqrt(magB)
        return den > 0 ? dot/den : 0
    }
}
