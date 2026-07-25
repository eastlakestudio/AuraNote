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

/// VAD 边界打包区块（最多 10 段或累计最多 20 秒）
struct VADChunk {
    let chunkStart: Double
    let chunkEnd: Double
    let subBoundaries: [(start: Double, end: Double)]
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
    private var hybridDiarizer: SherpaOnnxDiarizer?
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

    private func getHybridDiarizer() throws -> SherpaOnnxDiarizer {
        if let d = hybridDiarizer {
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
        config.clustering.threshold = 0.1  // 极度严格聚类，只求完美切割
        config.clustering.numClusters = -1
        config.minDurationOn = SettingsManager.shared.minDurationOn
        config.minDurationOff = SettingsManager.shared.minDurationOff
        config.numThreads = 4

        let d = SherpaOnnxDiarizer()
        try d.create(config: config)
        self.hybridDiarizer = d

        AppLog.info("[DiarService] sherpa-onnx hybrid diarizer created (threshold=0.1)")
        return d
    }

    /// 释放所有 ONNX Runtime 会话，释放 ~500MB-1GB 内存
    func reset() {
        diarizer?.destroy()
        diarizer = nil
        hybridDiarizer?.destroy()
        hybridDiarizer = nil
        cachedThreshold = nil
        embeddingExtractor?.destroy()
        embeddingExtractor = nil
        AppLog.info("[DiarService] ONNX diarizers destroyed, memory released")
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

    /// URL 入参重载（从磁盘读取采样数据转接）
    func diarizeWithEmbeddings(
        audioURL: URL,
        onProgress: ((Float) -> Void)? = nil,
        onChunkDiarized: (([DiarizedSegment]) async -> Void)? = nil
    ) async throws -> DiarizationOutput {
        let samples = try await loadAudioSamples(audioURL)
        return try await diarizeWithEmbeddings(samples: samples, audioURL: audioURL, onProgress: onProgress, onChunkDiarized: onChunkDiarized)
    }

    /// 离线高精声纹分离（sherpa-onnx 内置 Pyannote 3.0 切片 + 0.90 FastClustering HAC 聚类）
    func diarizeWithEmbeddings(
        samples: [Float],
        audioURL: URL? = nil,
        onProgress: ((Float) -> Void)? = nil,
        onIncrementalResult: (([DiarizedSegment], [String: [Float]]) async -> Void)? = nil,
        onChunkDiarized: (([DiarizedSegment]) async -> Void)? = nil
    ) async throws -> DiarizationOutput {
        let startTime = Date()
        let name = audioURL?.lastPathComponent ?? "in-memory-buffer"
        AppLog.info("[DiarService] Hybrid diarization start: audio=\(name)")

        let audioDuration = Double(samples.count) / 16000.0
        AppLog.info("[DiarService] audio loaded: \(samples.count) samples @ 16kHz, duration=\(String(format: "%.1f", audioDuration))s")

        // 1. 能量 VAD 粗筛 (离线文件由于音量不确定，使用极低的阈值防止误删轻音)
        let vadSegments = energyVADSegments(samples: samples, threshold: 0.002)
        AppLog.info("[DiarService] Energy VAD detected \(vadSegments.count) chunks")

        let clustering = IncrementalSpeakerClustering()
        var labeledSubSegments: [(start: Double, end: Double, label: String, embedding: [Float])] = []
        var processedDuration: Double = 0
        var lastMergeDuration: Double = 0
        var lastCallbackTime = Date.distantPast
        
        // 增量维护：避免每 chunk 全量重建 O(n²) 退化
        var accumulatedSegments: [DiarizedSegment] = []
        var speakerEmbeddingSums: [String: [Float]] = [:]
        var speakerEmbeddingCounts: [String: Int] = [:]
        var lastSegmentIndex: [String: Int] = [:]   // speaker → accumulatedSegments 尾段索引
        var lastLabeledIndex: Int = 0                // labeledSubSegments 已增量处理到的位置
        
        // 预创建 Neural VAD diarizer 并复用（创建 CoreML diarizer 耗时 2-3s，循环外创建一次即可）
        let hybridDiarizer = SherpaOnnxDiarizer()
        var hybridConfig = SherpaDiarizationConfig()
        hybridConfig.segmentationModel = segmentationModelPath()
        hybridConfig.embeddingModel = embeddingModelPath()
        hybridConfig.clustering.numClusters = -1
        hybridConfig.clustering.threshold = 0.1
        hybridConfig.minDurationOn = SettingsManager.shared.minDurationOn
        hybridConfig.minDurationOff = SettingsManager.shared.minDurationOff
        try hybridDiarizer.create(config: hybridConfig)
        
        for (idx, vadSeg) in vadSegments.enumerated() {
            // 支持外部取消（用户退出会议时及时释放资源）
            try Task.checkCancellation()
            
            let startSample = Int(vadSeg.start * 16000)
            let endSample = min(Int(vadSeg.end * 16000), samples.count)
            guard startSample < endSample else { continue }
            
            var chunkSamples = Array(samples[startSample..<endSample])
            
            // 2. Neural VAD 精细切割与 ERes2Net 声纹提取（使用完整音频做上下文填充）
            let hybridSegs = await extractHybridSegments(
                from: chunkSamples,
                allSamples: samples,
                globalOffset: vadSeg.start,
                diarizer: hybridDiarizer
            )
            chunkSamples.removeAll()  // 立即释放 chunk 拷贝
            
            var currentChunkSegments: [DiarizedSegment] = []
            for sub in hybridSegs {
                let duration = sub.end - sub.start
                let label = await clustering.addEmbedding(sub.embedding, duration: duration)
                
                // 将相对 chunk 的时间轴转换为全局时间轴
                let globalStart = vadSeg.start + sub.start
                let globalEnd = vadSeg.start + sub.end
                
                labeledSubSegments.append((
                    start: globalStart,
                    end: globalEnd,
                    label: label,
                    embedding: sub.embedding
                ))
                
                // 允许最多 0.5 秒的同人断点合并，且合并后总长度不超过 30 秒，防止转写超载
                if let last = currentChunkSegments.last, 
                   last.speakerId == label, 
                   globalStart - last.endTime <= 0.5,
                   globalEnd - last.startTime <= 30.0 {
                    currentChunkSegments[currentChunkSegments.count - 1] = DiarizedSegment(
                        speakerId: label,
                        startTime: last.startTime,
                        endTime: max(last.endTime, globalEnd)
                    )
                } else {
                    currentChunkSegments.append(DiarizedSegment(
                        speakerId: label,
                        startTime: globalStart,
                        endTime: globalEnd
                    ))
                }
            }
            
            if let onChunkDiarized = onChunkDiarized, !currentChunkSegments.isEmpty {
                await onChunkDiarized(currentChunkSegments)
            }
            
            processedDuration += (vadSeg.end - vadSeg.start)
            
            // 每处理 30 秒进行一次全局合并消除局部冗余
            if processedDuration - lastMergeDuration >= 30.0 {
                let partialRemap = await clustering.mergeSimilarClusters()
                if !partialRemap.isEmpty {
                    for i in 0..<labeledSubSegments.count {
                        if let newLabel = partialRemap[labeledSubSegments[i].label] {
                            labeledSubSegments[i].label = newLabel
                        }
                    }
                    // 聚类合并后标签已变，全量重建增量状态（每 ~30s 一次，可接受）
                    let rebuilt = buildDiarizationOutput(from: labeledSubSegments, remap: nil)
                    accumulatedSegments = rebuilt.segments
                    speakerEmbeddingSums.removeAll()
                    speakerEmbeddingCounts.removeAll()
                    lastSegmentIndex.removeAll()
                    for seg in labeledSubSegments {
                        if speakerEmbeddingSums[seg.label] == nil {
                            speakerEmbeddingSums[seg.label] = seg.embedding
                            speakerEmbeddingCounts[seg.label] = 1
                        } else {
                            let dim = seg.embedding.count
                            for j in 0..<dim {
                                speakerEmbeddingSums[seg.label]![j] += seg.embedding[j]
                            }
                            speakerEmbeddingCounts[seg.label]! += 1
                        }
                    }
                    for (i, seg) in accumulatedSegments.enumerated() {
                        lastSegmentIndex[seg.speakerId] = i
                    }
                    lastLabeledIndex = labeledSubSegments.count
                }
                lastMergeDuration = processedDuration
            }
            
            onProgress?(Float(processedDuration / audioDuration))
            
            // 抛出增量结果：仅处理本轮新增段，O(新增) 而非 O(全量)
            if let onIncrementalResult = onIncrementalResult {
                let now = Date()
                if now.timeIntervalSince(lastCallbackTime) >= 3.0 || processedDuration < 60.0 {
                    // 增量合并本轮新增的 sub-segment
                    let newSubSegs = labeledSubSegments[lastLabeledIndex...]
                    for seg in newSubSegs {
                        // 更新声纹累加和
                        if speakerEmbeddingSums[seg.label] == nil {
                            speakerEmbeddingSums[seg.label] = seg.embedding
                            speakerEmbeddingCounts[seg.label] = 1
                        } else {
                            let dim = seg.embedding.count
                            for j in 0..<dim {
                                speakerEmbeddingSums[seg.label]![j] += seg.embedding[j]
                            }
                            speakerEmbeddingCounts[seg.label]! += 1
                        }
                        // 仅与同一说话人的最后一个段合并（O(1)，不扫全量）
                        if let lastIdx = lastSegmentIndex[seg.label],
                           lastIdx < accumulatedSegments.count {
                            let lastSeg = accumulatedSegments[lastIdx]
                            if seg.start <= lastSeg.endTime + 0.1 {
                                accumulatedSegments[lastIdx] = DiarizedSegment(
                                    speakerId: seg.label,
                                    startTime: lastSeg.startTime,
                                    endTime: max(lastSeg.endTime, seg.end)
                                )
                                continue
                            }
                        }
                        // 无法合并，追加新段
                        accumulatedSegments.append(DiarizedSegment(
                            speakerId: seg.label,
                            startTime: seg.start,
                            endTime: seg.end
                        ))
                        lastSegmentIndex[seg.label] = accumulatedSegments.count - 1
                    }
                    lastLabeledIndex = labeledSubSegments.count
                    
                    // 计算各说话人平均声纹
                    var avgEmbeddings: [String: [Float]] = [:]
                    for (speaker, sum) in speakerEmbeddingSums {
                        guard let count = speakerEmbeddingCounts[speaker], count > 0 else { continue }
                        let dim = sum.count
                        var avg = [Float](repeating: 0, count: dim)
                        for j in 0..<dim { avg[j] = sum[j] / Float(count) }
                        avgEmbeddings[speaker] = avg
                    }
                    
                    await onIncrementalResult(accumulatedSegments, avgEmbeddings)
                    lastCallbackTime = now
                }
            }
            
            AppLog.info("[DiarService] Processed chunk \(idx + 1)/\(vadSegments.count)")
        }
        
        // 3. 最终全局二次合并与重叠去重
        let remap = await clustering.mergeSimilarClusters()
        let finalOutput = buildDiarizationOutput(from: labeledSubSegments, remap: remap)
        
        let outputSegments = finalOutput.segments
        let rawEmbeddings = finalOutput.embeddings
        
        // 最终合并后最后一次回调，确保外部拿到完整的最终结果
        if let onIncrementalResult = onIncrementalResult {
            await onIncrementalResult(outputSegments, rawEmbeddings)
        }
        
        onProgress?(1.0)
        let processElapsed = Date().timeIntervalSince(startTime)
        let uniqueSpeakers = Set(outputSegments.map(\.speakerId))
        AppLog.info("[DiarService] Hybrid result: \(uniqueSpeakers.count) speakers, \(outputSegments.count) segments (elapsed: \(String(format: "%.1f", processElapsed))s)")
        
        // 释放 hybridDiarizer（ONNX 会话），避免分析结束后 arena 内存残留
        hybridDiarizer.destroy()
        labeledSubSegments.removeAll()
        
        return DiarizationOutput(segments: outputSegments, embeddings: rawEmbeddings)
    }

    /// 基于外部给定的句边界进行声纹分离（与转写句边界严格 1:1 对齐）
    /// - Parameters:
    ///   - samples: 完整音频采样
    ///   - boundaries: 句边界数组 (startTime, endTime)，通常来自转录输出
    ///   - onProgress: 进度回调 0.0~1.0
    /// - Returns: 声纹分离结果，segments 数量 = boundaries 数量（1:1 对齐）
    func diarizeWithSentenceBoundaries(
        samples: [Float],
        boundaries: [(start: Double, end: Double)],
        onProgress: ((Float) -> Void)? = nil
    ) async throws -> DiarizationOutput {
        let startTime = Date()
        let audioDuration = Double(samples.count) / 16000.0
        AppLog.info("[DiarService] Sentence-level diarization: \(boundaries.count) boundaries, \(String(format: "%.1f", audioDuration))s audio")

        let clustering = IncrementalSpeakerClustering()
        var labeledSegments: [(start: Double, end: Double, label: String, embedding: [Float])] = []

        let ex = try getEmbeddingExtractor()
        let totalSamples = samples.count

        for (idx, bound) in boundaries.enumerated() {
            try Task.checkCancellation()

            let startSample = Int(bound.start * 16000)
            let endSample = min(Int(bound.end * 16000), totalSamples)
            guard startSample < endSample else { continue }

            // 用 prepareSamplesWithContext 自动填充上下文至 ≥1.6s，
            // eres2net 需要足够长音频才能提取有意义的声纹向量
            let segSamples = Self.prepareSamplesWithContext(allSamples: samples, startSec: bound.start, endSec: bound.end)
            guard let emb = try? ex.extractEmbedding(samples: segSamples, sampleRate: 16000) else {
                AppLog.info("[DiarService] Sentence-level diar: segment \(idx) [\(String(format: "%.2f", bound.start))s-\(String(format: "%.2f", bound.end))s] embedding failed, skipping")
                continue
            }

            let duration = bound.end - bound.start
            let label = await clustering.addEmbedding(emb, duration: duration)

            labeledSegments.append((start: bound.start, end: bound.end, label: label, embedding: emb))

            onProgress?(Float(idx + 1) / Float(boundaries.count))
        }

        // 最终合并相似聚类
        let remap = await clustering.mergeSimilarClusters()

        var segments: [DiarizedSegment] = []
        for seg in labeledSegments {
            let finalLabel = remap[seg.label] ?? seg.label
            segments.append(DiarizedSegment(speakerId: finalLabel, startTime: seg.start, endTime: seg.end))
        }

        // 计算各说话人平均声纹向量
        var embeddingSums: [String: [Float]] = [:]
        var embeddingCounts: [String: Int] = [:]
        for seg in labeledSegments {
            let finalLabel = remap[seg.label] ?? seg.label
            if embeddingSums[finalLabel] == nil {
                embeddingSums[finalLabel] = seg.embedding
                embeddingCounts[finalLabel] = 1
            } else {
                let dim = seg.embedding.count
                for j in 0..<dim {
                    embeddingSums[finalLabel]![j] += seg.embedding[j]
                }
                embeddingCounts[finalLabel]! += 1
            }
        }

        var avgEmbeddings: [String: [Float]] = [:]
        for (speaker, sum) in embeddingSums {
            guard let count = embeddingCounts[speaker], count > 0 else { continue }
            avgEmbeddings[speaker] = sum.enumerated().map { $0.element / Float(count) }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let uniqueSpeakers = Set(segments.map(\.speakerId))
        AppLog.info("[DiarService] Sentence-level result: \(uniqueSpeakers.count) speakers, \(segments.count) segments (elapsed: \(String(format: "%.1f", elapsed))s)")

        return DiarizationOutput(segments: segments, embeddings: avgEmbeddings)
    }

    // MARK: - 说话人切换点切句

    /// 使用独立 VAD 级声纹分离结果，在说话人切换点切分 ASR 句子
    ///
    /// 原理：ASR 分句基于语义/标点，不感知说话人变化。当两人在 ASR 一句内快速交替发言时，
    /// 整句会被错误合并。此函数用 VAD 级声纹分离（pyannote 分割 + 聚类）的说话人切换时间点，
    /// 将跨说话人的 ASR 句子在切换边界处切开。
    ///
    /// - Parameters:
    ///   - sentences: FunASR 产出的句级片段
    ///   - diarSegments: diarizeSegmented 产出的 VAD 级声纹分离段（时间精度远高于 ASR 句边界）
    /// - Returns: 切分并标注好说话人的新句段列表
    nonisolated func intersectAndLabel(
        sentences: [TranscriptSegment],
        diarSegments: [DiarizedSegment]
    ) -> [TranscriptSegment] {
        guard !diarSegments.isEmpty else {
            return sentences.map { seg in
                var s = seg
                s.speakerLabel = "?"
                return s
            }
        }

        let sortedDiar = diarSegments.sorted { $0.startTime < $1.startTime }
        var result: [TranscriptSegment] = []

        for sentence in sentences {
            // 找到所有与此句子时间重叠的声纹分离段
            let overlapping = sortedDiar.filter {
                $0.startTime < sentence.endTime && $0.endTime > sentence.startTime
            }

            guard !overlapping.isEmpty else {
                var seg = sentence
                seg.speakerLabel = "?"
                result.append(seg)
                continue
            }

            // 将连续同说话人的段合并为一个区间
            var speakerGroups: [(speakerId: String, start: Double, end: Double)] = []
            for diarSeg in overlapping {
                let clampedStart = max(diarSeg.startTime, sentence.startTime)
                let clampedEnd = min(diarSeg.endTime, sentence.endTime)
                if let last = speakerGroups.last,
                   last.speakerId == diarSeg.speakerId,
                   clampedStart <= last.end + 0.1 {
                    // 同一说话人且时间相近 → 合并
                    speakerGroups[speakerGroups.count - 1].end = max(last.end, clampedEnd)
                } else {
                    speakerGroups.append((speakerId: diarSeg.speakerId, start: clampedStart, end: clampedEnd))
                }
            }

            if speakerGroups.count == 1 {
                // 单说话人：直接标注
                var seg = sentence
                seg.speakerLabel = speakerGroups[0].speakerId
                result.append(seg)
            } else {
                // 多说话人：不再切分文本，因为缺乏字级时间戳会导致按比例切分极度不准。
                // 而是计算哪个说话人在该句子期间重叠时间最长，将其作为主导说话人分配给整个句子。
                var maxDuration: Double = -1
                var dominantSpeaker = "?"
                
                for group in speakerGroups {
                    let dur = group.end - group.start
                    if dur > maxDuration {
                        maxDuration = dur
                        dominantSpeaker = group.speakerId
                    }
                }
                
                AppLog.info("[DiarService] Sentence \(sentence.id) has multiple speakers (\(speakerGroups.count)), assigning to dominant speaker: \(dominantSpeaker)")
                var seg = sentence
                seg.speakerLabel = dominantSpeaker
                result.append(seg)
            }
        }

        let splitCount = result.filter { $0.id.contains("_sp") }.count
        if splitCount > 0 {
            AppLog.info("[DiarService] intersectAndLabel: \(sentences.count) sentences → \(result.count) segments (\(splitCount) from speaker splits)")
        }
        return result
    }

    /// 用 tokenTimestamps 估算子段的精确 endTime（开始时间 + token 时长）。
    /// - 句末字符：用 Paraformer 返回的精确 token 时长
    /// - 非句末字符：找下一个不同时间戳的字符，时间差 ≈ token 时长
    private nonisolated func computeSubSegmentEnd(
        ts: [Double],
        charIdx: Int,
        lastTokenDuration: Double
    ) -> Double {
        let lastIdx = min(ts.count - 1, max(0, charIdx))
        let lastTs = ts[lastIdx]
        var estimatedDur: Double
        if lastIdx == ts.count - 1 {
            estimatedDur = lastTokenDuration
        } else {
            var nextIdx = lastIdx + 1
            while nextIdx < ts.count && ts[nextIdx] == lastTs { nextIdx += 1 }
            if nextIdx < ts.count {
                estimatedDur = min(ts[nextIdx] - lastTs, 2.0)
            } else {
                estimatedDur = 0.2
            }
        }
        return lastTs + estimatedDur
    }

    /// 按时间比例将文本分配到各子段。
    /// 在标点符号处对齐切分点，使每段文本尽可能对应其时间区间。
    private nonisolated func splitTextByTimeRatio(
        _ text: String,
        segments: [(Double, Double)],
        sentenceStart: Double,
        sentenceEnd: Double
    ) -> [String] {
        let totalDuration = sentenceEnd - sentenceStart
        guard totalDuration > 0, !text.isEmpty, segments.count > 1 else {
            return [text]
        }

        let chars = Array(text)
        let totalChars = chars.count

        // 收集所有标点位置
        let punctSet = Set<Character>(["，", "。", "！", "？", "；", "：", "、", ",", ".", "!", "?"])
        var punctIndices: [Int] = []
        for (i, ch) in chars.enumerated() {
            if punctSet.contains(ch) {
                punctIndices.append(i)
            }
        }

        // 计算每段应得的字符数（按时长比例），预分配避免窄段被吞
        var charBudgets: [Int] = []
        for i in 0..<(segments.count - 1) {
            let dur = segments[i].1 - segments[i].0
            charBudgets.append(max(1, Int((dur / totalDuration) * Double(totalChars))))
        }
        // 最后一段拿剩余
        let used = charBudgets.reduce(0, +)
        charBudgets.append(max(1, totalChars - used))

        var result: [String] = []
        var prevCharIdx = 0

        for i in 0..<(segments.count - 1) {
            var targetCharIdx = min(prevCharIdx + charBudgets[i], totalChars - 1)

            // 找到最近的标点作为切分点
            if !punctIndices.isEmpty {
                var bestPunct = targetCharIdx
                var bestDist = Int.max
                for p in punctIndices {
                    if p <= prevCharIdx { continue }
                    let dist = abs(p - targetCharIdx)
                    // 只接受合理距离内的标点（不超过剩余文本的一半）
                    if dist < bestDist, dist <= (totalChars - prevCharIdx) / 2 {
                        bestDist = dist
                        bestPunct = p
                    }
                }
                if bestDist < Int.max {
                    targetCharIdx = bestPunct
                }
            }

            // 确保至少前进一个字符
            targetCharIdx = max(prevCharIdx, min(targetCharIdx, totalChars - 2))

            let chunk = String(chars[prevCharIdx...targetCharIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(chunk)
            prevCharIdx = targetCharIdx + 1
        }

        // 最后一段取剩余全部文本
        if prevCharIdx < totalChars {
            let chunk = String(chars[prevCharIdx...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(chunk)
        } else {
            result.append("")
        }

        return result
    }

    /// 用 Paraformer token 级时间戳精确切分文本，替代按时长比例的盲猜。
    ///
    /// 每个字符有独立的音频时间戳（来自 Paraformer 的 tokens_arr + timestamps），
    /// 在说话人切换边界时间点 B 处，找到时间戳最接近 B 的字符位置，在最近的标点处切开。
    /// 这样不受语速差异影响——语速快的说话人自然分配到更多字符。
    ///
    /// - Parameters:
    ///   - text: 句子文本
    ///   - tokenTimestamps: 与 text 字符一一对应的时间戳数组，nil 时退化为 splitTextByTimeRatio
    ///   - segments: 各说话人段的时间区间
    ///   - sentenceStart: 原始句起始时间
    ///   - sentenceEnd: 原始句结束时间
    /// - Returns: 按说话人切分后的子文本数组
    private nonisolated func splitTextByTokenTimestamps(
        _ text: String,
        tokenTimestamps: [Double]?,
        segments: [(Double, Double)],
        sentenceStart: Double,
        sentenceEnd: Double
    ) -> [String] {
        // 无 token 级时间戳 → 回退到时长比例盲猜
        guard let ts = tokenTimestamps, ts.count == text.count, segments.count > 1 else {
            return splitTextByTimeRatio(text, segments: segments,
                                        sentenceStart: sentenceStart, sentenceEnd: sentenceEnd)
        }

        let chars = Array(text)
        let punctSet = Set<Character>(["，", "。", "！", "？", "；", "：", "、", ",", ".", "!", "?"])
        var result: [String] = []
        var prevCharIdx = 0

        for i in 0..<(segments.count - 1) {
            // 段 i 与段 i+1 之间的 Pyannote 切换时间点（有 ±200ms 误差）
            let boundaryTime = segments[i].1

            // 在 Pyannote 边界 ±500ms 内，找 token 时间戳的最大跳变（自然停顿）
            // 说话人切换通常有短暂停顿，表现为相邻字符时间戳的跳变
            var splitIdx = prevCharIdx
            let searchWindow: Double = 0.5
            var bestGap: Double = 0
            var bestGapIdx = prevCharIdx
            for idx in prevCharIdx..<(chars.count - 1) {
                guard abs(ts[idx] - boundaryTime) <= searchWindow else { continue }
                let gap = ts[idx + 1] - ts[idx]
                if gap > bestGap { bestGap = gap; bestGapIdx = idx }
            }
            if bestGap > 0.05 {
                splitIdx = bestGapIdx
            } else {
                var bestDist = Double.infinity
                for idx in prevCharIdx..<chars.count {
                    let dist = abs(ts[idx] - boundaryTime)
                    if dist < bestDist { bestDist = dist; splitIdx = idx }
                }
            }

            // 在最近的标点处微调
            let maxAhead = min(chars.count - 1, splitIdx + 5)
            if let punctPos = (splitIdx...maxAhead).first(where: { punctSet.contains(chars[$0]) }) {
                splitIdx = punctPos
            } else {
                let minBehind = max(0, splitIdx - 3)
                if let punctPos = (minBehind...splitIdx).reversed().first(where: { punctSet.contains(chars[$0]) }) {
                    splitIdx = punctPos
                }
            }

            // 确保至少前进一个字符
            splitIdx = max(prevCharIdx, min(splitIdx, chars.count - 2))

            let chunk = String(chars[prevCharIdx...splitIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(chunk)
            prevCharIdx = splitIdx + 1
        }

        // 最后一段取剩余全部文本
        if prevCharIdx < chars.count {
            result.append(String(chars[prevCharIdx...])
                .trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            result.append("")
        }

        return result
    }

    /// 二次校验：对已标注但可能漏掉说话人切换的句子，通过比较前半段与后半段的
    /// 声纹向量来检测被聚类合并的隐藏说话人变化。
    ///
    /// 当两个说话人声纹特征相似导致增量聚类将它们合并为同一人时，
    /// intersectAndLabel 无法切句。此函数对每个已标注句子做句内前后半段声纹对比：
    /// 若余弦距离 > splitThreshold → 在时间中点强制切开。
    ///
    /// - Parameters:
    ///   - sentences: intersectAndLabel 已标注说话人的句子列表
    ///   - samples: 完整音频采样（16kHz float32）
    /// - Returns: 可能被进一步切分的句子列表
    func refineWithEmbeddingSplit(
        sentences: [TranscriptSegment],
        samples: [Float]
    ) async throws -> [TranscriptSegment] {
        let ex = try getEmbeddingExtractor()
        let totalSamples = samples.count
        let sampleRate = 16000.0

        // 句内前后半段声纹差异阈值（余弦距离 0~2），从系统配置读取
        let splitThreshold = SettingsManager.shared.embeddingSplitThreshold

        var result: [TranscriptSegment] = []
        var splitCount = 0

        for sentence in sentences {
            let duration = sentence.endTime - sentence.startTime
            // 跳过太短的句子（< 2s → 前后半段各 < 1s，声纹不可靠）
            guard duration >= 2.0 else {
                result.append(sentence)
                continue
            }

            let midTime = (sentence.startTime + sentence.endTime) / 2.0
            let firstStart = Int(sentence.startTime * sampleRate)
            let firstEnd = Int(midTime * sampleRate)
            let secondStart = firstEnd
            let secondEnd = min(Int(sentence.endTime * sampleRate), totalSamples)

            guard firstStart < firstEnd, secondStart < secondEnd else {
                result.append(sentence)
                continue
            }

            let firstHalf = Array(samples[firstStart..<firstEnd])
            let secondHalf = Array(samples[secondStart..<secondEnd])

            guard let emb1 = try? ex.extractEmbedding(samples: firstHalf),
                  let emb2 = try? ex.extractEmbedding(samples: secondHalf) else {
                result.append(sentence)
                continue
            }

            let dist = cosineDistance(emb1, emb2)

            if dist > splitThreshold {
                AppLog.info("[DiarService] Embedding discontinuity in \(sentence.id): dist=\(String(format: "%.4f", dist)) > \(String(format: "%.4f", splitThreshold)), assigning to ? instead of splitting")

                var updatedSentence = sentence
                updatedSentence.speakerLabel = "?"
                updatedSentence.contactId = nil
                result.append(updatedSentence)

                splitCount += 1
            } else {
                result.append(sentence)
            }
        }

        if splitCount > 0 {
            AppLog.info("[DiarService] refineWithEmbeddingSplit: \(splitCount) sentence(s) split by embedding discontinuity")
        }
        return result
    }

    /// 余弦距离（0~2），与 sherpa-onnx FastClustering 语义一致，distance = 1 - cos_sim
    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let den = sqrt(magA) * sqrt(magB)
        let sim = den > 0 ? max(-1, min(1, dot / den)) : 0
        return max(0, min(2, 1 - sim))
    }

    private func buildDiarizationOutput(
        from labeledSubSegments: [(start: Double, end: Double, label: String, embedding: [Float])],
        remap: [String: String]? = nil
    ) -> DiarizationOutput {
        var segments = labeledSubSegments
        if let remap = remap, !remap.isEmpty {
            for i in 0..<segments.count {
                if let newLabel = remap[segments[i].label] {
                    segments[i].label = newLabel
                }
            }
        }
        
        var mergedFinalSegments: [(start: Double, end: Double, label: String, embedding: [Float])] = []
        let groupedByLabel = Dictionary(grouping: segments, by: { $0.label })
        
        for (label, group) in groupedByLabel {
            let sorted = group.sorted { $0.start < $1.start }
            var currentMerged: [(start: Double, end: Double, label: String, embedding: [Float])] = []
            
            for seg in sorted {
                if let last = currentMerged.last, seg.start <= last.end + 0.1 {
                    currentMerged[currentMerged.count - 1] = (
                        start: last.start,
                        end: max(last.end, seg.end),
                        label: label,
                        embedding: seg.embedding
                    )
                } else {
                    currentMerged.append(seg)
                }
            }
            mergedFinalSegments.append(contentsOf: currentMerged)
        }
        
        mergedFinalSegments.sort { $0.start < $1.start }
        
        var outputSegments: [DiarizedSegment] = []
        for seg in mergedFinalSegments {
            outputSegments.append(DiarizedSegment(
                speakerId: seg.label,
                startTime: seg.start,
                endTime: seg.end
            ))
        }
        
        var rawEmbeddings: [String: [Float]] = [:]
        for (label, group) in Dictionary(grouping: mergedFinalSegments, by: { $0.label }) {
            let allEmbs = group.map { $0.embedding }
            guard !allEmbs.isEmpty else { continue }
            let dim = allEmbs[0].count
            var avg = [Float](repeating: 0, count: dim)
            for emb in allEmbs {
                for j in 0..<dim { avg[j] += emb[j] }
            }
            for j in 0..<dim { avg[j] /= Float(allEmbs.count) }
            rawEmbeddings[label] = avg
        }
        
        return DiarizationOutput(segments: outputSegments, embeddings: rawEmbeddings)
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
                AppLog.info("[DiarService] VAD Segment #\(i + 1)/\(vadSegments.count) [\(String(format: "%.2f", seg.start))s - \(String(format: "%.2f", seg.end))s] skipped (invalid sample bounds)")
                skippedCount += 1
                onEmbeddingProgress(i + 1, vadSegments.count)
                continue
            }
            let segSamples = Self.prepareSamplesWithContext(allSamples: samples, startSec: seg.start, endSec: seg.end)
            let segDuration = seg.end - seg.start

            // 跳过过短片段（< 0.3s，声纹不可靠）
            guard segDuration >= 0.3 else {
                AppLog.info("[DiarService] VAD Segment #\(i + 1)/\(vadSegments.count) [\(String(format: "%.2f", seg.start))s - \(String(format: "%.2f", seg.end))s] (dur: \(String(format: "%.2f", segDuration))s) skipped (duration < 0.3s)")
                skippedCount += 1
                onEmbeddingProgress(i + 1, vadSegments.count)
                continue
            }

            do {
                let emb = try ex.extractEmbedding(samples: segSamples, sampleRate: 16000)
                // 即时聚类：每提取一个 embedding 就归入聚类，无需等全部完成
                let label = await clustering.addEmbedding(emb, duration: segDuration)
                speakerEmbeddingLists[label, default: []].append(emb)

                AppLog.info("[DiarService] VAD Segment #\(i + 1)/\(vadSegments.count) [\(String(format: "%.2f", seg.start))s - \(String(format: "%.2f", seg.end))s] (dur: \(String(format: "%.2f", segDuration))s) -> assigned to \(label)")

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
    /// - Parameter pauseWindow: 静音持续多久算作段落边界（秒），默认使用 SettingsManager 配置值
    nonisolated func energyVADSegments(
        samples: [Float],
        pauseWindow: Double? = nil,
        threshold: Float? = nil
    ) -> [(start: Double, end: Double)] {
        let s = SettingsManager.shared
        let silenceThreshold: Float = threshold ?? s.silenceThreshold
        let effectivePauseWindow = pauseWindow ?? s.pauseWindow
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
                    if silenceDuration >= effectivePauseWindow {
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
    
    /// 核心处理循环：按 20s/10段 打包 Chunk + 提取 Chunk 声纹 + 时间重叠映射赋给 Whisper 句段
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
        var processedChunkCount = 0
        var skippedCount = 0

        /// 处理单个打包 Chunk（包含 chunkStart...chunkEnd 以及子句段 subBoundaries）
        func processChunk(_ chunk: VADChunk) async {
            processedChunkCount += 1
            let chunkStart = chunk.chunkStart
            let chunkEnd = chunk.chunkEnd
            let chunkDuration = chunkEnd - chunkStart

            let startIdx = Int(chunkStart * 16000)
            let endIdx = min(Int(chunkEnd * 16000), samples.count)
            guard startIdx < endIdx, chunkDuration >= 0.3 else {
                skippedCount += chunk.subBoundaries.count
                return
            }

            let windowSec = 1.6
            let stepSec = 0.8

            var subSegments: [(label: String, start: Double, end: Double)] = []

            for subBoundary in chunk.subBoundaries {
                let subStart = subBoundary.start
                let subEnd = subBoundary.end
                let subDuration = subEnd - subStart

                let sIdx = Int(subStart * 16000)
                let eIdx = min(Int(subEnd * 16000), samples.count)
                guard sIdx < eIdx, subDuration >= 0.3 else {
                    continue
                }

                if subDuration <= windowSec {
                    let winSamples = Self.prepareSamplesWithContext(allSamples: samples, startSec: subStart, endSec: subEnd)
                    do {
                        let emb = try extractor.extractEmbedding(samples: winSamples, sampleRate: 16000)
                        let label = await clustering.addEmbedding(emb, duration: subDuration)
                        speakerEmbeddingLists[label, default: []].append(emb)
                        subSegments.append((label: label, start: subStart, end: subEnd))
                    } catch {
                        AppLog.warn("[DiarService] embedding extraction failed for subBoundary [\(subStart)-\(subEnd)]: \(error)")
                    }
                } else {
                    var currStart = subStart
                    while currStart < subEnd {
                        let currEnd = min(currStart + windowSec, subEnd)
                        if (currEnd - currStart) >= 0.3 {
                            let winSamples = Self.prepareSamplesWithContext(allSamples: samples, startSec: currStart, endSec: currEnd)
                            if let emb = try? extractor.extractEmbedding(samples: winSamples, sampleRate: 16000) {
                                let label = await clustering.addEmbedding(emb, duration: currEnd - currStart)
                                speakerEmbeddingLists[label, default: []].append(emb)
                                subSegments.append((label: label, start: currStart, end: currEnd))
                            }
                        }
                        if currEnd >= subEnd { break }
                        currStart += stepSec
                    }
                }
            }

            if subSegments.isEmpty {
                skippedCount += chunk.subBoundaries.count
                return
            }

            // 合并连续相同 Speaker 的窗口区间
            var mergedSub: [DiarizedSegment] = []
            for sub in subSegments {
                if let last = mergedSub.last, last.speakerId == sub.label {
                    mergedSub[mergedSub.count - 1] = DiarizedSegment(speakerId: last.speakerId, startTime: last.startTime, endTime: sub.end)
                } else {
                    mergedSub.append(DiarizedSegment(speakerId: sub.label, startTime: sub.start, endTime: sub.end))
                }
            }

            // 孤立短标签平滑过滤（Smoothing Filter）
            var smoothedSub: [DiarizedSegment] = []
            var sIdx = 0
            while sIdx < mergedSub.count {
                let current = mergedSub[sIdx]
                let dur = current.endTime - current.startTime
                if dur < 0.8 && sIdx > 0 && sIdx < mergedSub.count - 1 {
                    let prev = mergedSub[sIdx - 1]
                    let next = mergedSub[sIdx + 1]
                    if prev.speakerId == next.speakerId {
                        let updatedPrev = DiarizedSegment(speakerId: prev.speakerId, startTime: prev.startTime, endTime: current.endTime)
                        smoothedSub[smoothedSub.count - 1] = updatedPrev
                        sIdx += 1
                        continue
                    }
                }
                smoothedSub.append(current)
                sIdx += 1
            }
            mergedSub = smoothedSub

            // 【核心关键点】：使用时间重叠最大化匹配，将 Chunk 声纹区间精准分配回每个 Whisper 原生 VAD 句段
            var chunkOutput: [DiarizedSegment] = []
            for subBoundary in chunk.subBoundaries {
                let assignedSpeaker = Self.assignSpeakerByOverlap(
                    segStart: subBoundary.start,
                    segEnd: subBoundary.end,
                    speakerIntervals: mergedSub
                )
                chunkOutput.append(DiarizedSegment(
                    speakerId: assignedSpeaker,
                    startTime: subBoundary.start,
                    endTime: subBoundary.end
                ))
            }

            outputSegments.append(contentsOf: chunkOutput)

            let spkSummary = Set(chunkOutput.map(\.speakerId)).sorted().joined(separator: ", ")
            AppLog.info("[DiarService] Chunk #\(processedChunkCount) [\(String(format: "%.2f", chunkStart))s - \(String(format: "%.2f", chunkEnd))s] (\(chunk.subBoundaries.count) Whisper segments) -> assigned to \(spkSummary)")

            // 计算当前各 Speaker 的平均声纹并流式回调
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
        }

        switch boundarySource {
        case .array(let boundaries):
            let chunks = Self.groupBoundaries(boundaries, maxCount: 4, maxDuration: 8.0)
            AppLog.info("[DiarService] Grouped \(boundaries.count) boundaries into \(chunks.count) chunks (max 4 segs / 8s)")
            for chunk in chunks {
                await processChunk(chunk)
            }
        case .stream(let stream):
            var currentBuffer: [(start: Double, end: Double)] = []
            for await boundary in stream {
                let namedBoundary = (start: boundary.0, end: boundary.1)
                if currentBuffer.isEmpty {
                    currentBuffer.append(namedBoundary)
                    continue
                }
                let firstStart = currentBuffer.first!.start
                let newEnd = namedBoundary.end
                let proposedDuration = newEnd - firstStart

                if currentBuffer.count >= 4 || proposedDuration >= 8.0 {
                    let chunk = VADChunk(
                        chunkStart: firstStart,
                        chunkEnd: currentBuffer.last!.end,
                        subBoundaries: currentBuffer
                    )
                    await processChunk(chunk)
                    currentBuffer = [namedBoundary]
                } else {
                    currentBuffer.append(namedBoundary)
                }
            }
            if !currentBuffer.isEmpty {
                let chunk = VADChunk(
                    chunkStart: currentBuffer.first!.start,
                    chunkEnd: currentBuffer.last!.end,
                    subBoundaries: currentBuffer
                )
                await processChunk(chunk)
            }
        }

        // 聚类级合并：全部 Chunk 处理完后，用充足数据量的簇质心互比，二次修正微小差异
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

        // 最终合并后回调，确保外部拿到完整的最终结果
        await onIncrementalResult(outputSegments, rawEmbeddings)

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
    
    /// [Hybrid Diarization 专用]
    /// 针对一整段连续音频（通常为外层能量 VAD 切割出的大段），内部使用极端严格的 Neural VAD (threshold=0.1) 提取纯净子片段。
    /// 针对每一个子片段 (>0.3s) 使用上下文填充（≥1.6s）后提取 eres2net 高精声纹。
    /// - Parameters:
    ///   - chunkSamples: 外层能量VAD切割出的单段音频
    ///   - allSamples: 完整音频采样（用于上下文填充）
    ///   - globalOffset: chunk 在完整音频中的起始时间（秒）
    func extractHybridSegments(
        from chunkSamples: [Float],
        allSamples: [Float],
        globalOffset: Double,
        diarizer: SherpaOnnxDiarizer? = nil
    ) async -> [(start: Double, end: Double, embedding: [Float])] {
        let segPath = segmentationModelPath()
        let embPath = embeddingModelPath()
        
        guard FileManager.default.fileExists(atPath: segPath),
              FileManager.default.fileExists(atPath: embPath) else {
            return []
        }
        
        do {
            let effectiveDiarizer: SherpaOnnxDiarizer
            if let diarizer = diarizer {
                effectiveDiarizer = diarizer
            } else {
                effectiveDiarizer = try getHybridDiarizer()
            }
            
            // 提取 Neural VAD 片段（在 chunk 上运行）
            let processResult = try effectiveDiarizer.process(samples: chunkSamples)
            let segments = processResult.segments
            
            // 复用 actor 级缓存的声纹提取器（单会话，避免重复创建 ONNX 会话导致内存泄漏）
            let ex = try getEmbeddingExtractor()
            
            var result: [(start: Double, end: Double, embedding: [Float])] = []
            
            for seg in segments {
                let duration = seg.end - seg.start
                if duration < 0.3 { continue } // 过滤过短无意义片段
                
                // 用 prepareSamplesWithContext 从完整音频中提取上下文填充后的采样（≥1.6s），
                // eres2net 需要足够长音频才能提取有意义的声纹向量
                let globalStart = globalOffset + Double(seg.start)
                let globalEnd = globalOffset + Double(seg.end)
                let ctxSamples = Self.prepareSamplesWithContext(
                    allSamples: allSamples,
                    startSec: globalStart,
                    endSec: globalEnd
                )
                if let emb = try? ex.extractEmbedding(samples: ctxSamples, sampleRate: 16000) {
                    result.append((start: Double(seg.start), end: Double(seg.end), embedding: emb))
                }
            }
            return result
        } catch {
            AppLog.warn("[DiarService] extractHybridSegments failed: \(error)")
            return []
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

    /// 提取指定音频片段采样，若时长小于 targetDuration（默认 1.6 秒），向前后安全扩展上下文，首尾不足时镜像/重复填充。
    /// 保障 sherpa-onnx eres2net 提取器获得足够且稳定维度的音频输入（≥ 25600 采样点 @ 16kHz）。
    static func prepareSamplesWithContext(
        allSamples: [Float],
        startSec: Double,
        endSec: Double,
        sampleRate: Int = 16000,
        targetDuration: Double = 1.6
    ) -> [Float] {
        let targetCount = Int(targetDuration * Double(sampleRate))
        let startIdx = max(0, Int(startSec * Double(sampleRate)))
        let endIdx = min(allSamples.count, Int(endSec * Double(sampleRate)))

        guard startIdx < endIdx else { return [] }

        let currentCount = endIdx - startIdx
        if currentCount >= targetCount {
            return Array(allSamples[startIdx..<endIdx])
        }

        let needed = targetCount - currentCount
        let halfNeeded = needed / 2

        var newStartIdx = max(0, startIdx - halfNeeded)
        let remainingNeeded = targetCount - (endIdx - newStartIdx)
        let newEndIdx = min(allSamples.count, endIdx + remainingNeeded)

        if newEndIdx - newStartIdx < targetCount {
            let leftCompensation = targetCount - (newEndIdx - newStartIdx)
            newStartIdx = max(0, newStartIdx - leftCompensation)
        }

        var extendedSamples = Array(allSamples[newStartIdx..<newEndIdx])

        while extendedSamples.count < targetCount {
            let padCount = targetCount - extendedSamples.count
            if extendedSamples.isEmpty { break }
            let copyChunk = Array(extendedSamples.prefix(padCount))
            extendedSamples.append(contentsOf: copyChunk)
        }

        return extendedSamples
    }

    /// 将有序的 VAD 边界列表按“最多 maxCount 段”且“最大累计时长 maxDuration 秒”打包成 Chunk 数组
    static func groupBoundaries(
        _ boundaries: [(start: Double, end: Double)],
        maxCount: Int = 15,
        maxDuration: Double = 30.0
    ) -> [VADChunk] {
        guard !boundaries.isEmpty else { return [] }

        var chunks: [VADChunk] = []
        var currentSub: [(start: Double, end: Double)] = []

        for b in boundaries {
            if currentSub.isEmpty {
                currentSub.append(b)
                continue
            }

            let firstStart = currentSub.first!.start
            let newEnd = b.end
            let proposedDuration = newEnd - firstStart

            if currentSub.count >= maxCount || proposedDuration > maxDuration {
                chunks.append(VADChunk(
                    chunkStart: firstStart,
                    chunkEnd: currentSub.last!.end,
                    subBoundaries: currentSub
                ))
                currentSub = [b]
            } else {
                currentSub.append(b)
            }
        }

        if !currentSub.isEmpty {
            chunks.append(VADChunk(
                chunkStart: currentSub.first!.start,
                chunkEnd: currentSub.last!.end,
                subBoundaries: currentSub
            ))
        }

        return chunks
    }

    /// 时间重叠最大化分配算法：对于单个 Whisper VAD 段 (segStart, segEnd)，
    /// 计算其与所有的 speakerIntervals [DiarizedSegment] 的重叠时长，选取重叠最大的 Speaker
    static func assignSpeakerByOverlap(
        segStart: Double,
        segEnd: Double,
        speakerIntervals: [DiarizedSegment],
        fallbackSpeaker: String = "?"
    ) -> String {
        var maxOverlap: Double = 0
        var bestSpeaker: String?

        for interval in speakerIntervals {
            let intersectStart = max(segStart, interval.startTime)
            let intersectEnd = min(segEnd, interval.endTime)
            let overlap = max(0.0, intersectEnd - intersectStart)

            if overlap > maxOverlap {
                maxOverlap = overlap
                bestSpeaker = interval.speakerId
            }
        }

        if let speaker = bestSpeaker, maxOverlap > 0 {
            return speaker
        }

        // 若无重叠（极端情况），找中心距离最近的区间
        let segCenter = (segStart + segEnd) / 2.0
        var minDistance = Double.infinity
        var closestSpeaker = fallbackSpeaker

        for interval in speakerIntervals {
            let center = (interval.startTime + interval.endTime) / 2.0
            let dist = abs(center - segCenter)
            if dist < minDistance {
                minDistance = dist
                closestSpeaker = interval.speakerId
            }
        }

        return closestSpeaker
    }
}
