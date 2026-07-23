import Foundation
import CSherpaOnnx

// MARK: - Configuration

/// 聚类配置
struct SherpaClusteringConfig {
    /// -1 = 自动判断人数；>0 = 显式指定说话人数
    var numClusters: Int32 = -1
    /// 距离阈值（余弦距离 0~2），numClusters == -1 时生效。越低越细分，说话人越多
    var threshold: Float = 0.90
}

/// 说话人分离完整配置
struct SherpaDiarizationConfig {
    /// pyannote 分割模型 ONNX 文件路径
    var segmentationModel: String = ""
    /// 声纹提取模型 ONNX 文件路径
    var embeddingModel: String = ""
    /// 聚类参数
    var clustering = SherpaClusteringConfig()
    /// 最短语音段（秒）
    var minDurationOn: Float = 0.3
    /// 最短静音间隔（秒）
    var minDurationOff: Float = 0.5
    /// 推理线程数
    var numThreads: Int32 = 4
}

// MARK: - Result Types

/// 一段说话人分离片段
struct SherpaDiarizationSegment {
    let start: Float
    let end: Float
    let speaker: Int32
}

/// 说话人分离结果
struct SherpaDiarizationResult {
    let numSpeakers: Int32
    let segments: [SherpaDiarizationSegment]
    let sampleRate: Int32
}

// MARK: - Diarizer (C handle wrapper)

/// sherpa-onnx 离线说话人分离器
final class SherpaOnnxDiarizer {
    /// 用 OpaquePointer 存储所有 C 句柄（兼容 Swift C 互操作）
    private var handle: OpaquePointer?
    private var sampleRate: Int32 = 0

    /// 创建分离器
    func create(config: SherpaDiarizationConfig) throws {
        destroy()

        guard !config.segmentationModel.isEmpty, !config.embeddingModel.isEmpty else {
            throw SherpaError.modelNotFound("分段模型或声纹模型路径为空")
        }

        // 使用 withCString 确保 C 字符串生命周期覆盖 Create 调用
        try config.segmentationModel.withCString { segModelPath in
            try config.embeddingModel.withCString { embModelPath in
                // 尝试 CoreML provider（Apple Silicon ANE 加速），不兼容则回退 CPU
                let providers = ["coreml", "cpu"]
                var lastError: Error? = nil
                for provider in providers {
                    do {
                        try provider.withCString { providerCStr in
                            var cConfig = SherpaOnnxOfflineSpeakerDiarizationConfig()
                            memset(&cConfig, 0, MemoryLayout<SherpaOnnxOfflineSpeakerDiarizationConfig>.size)

                            // segmentation (pyannote)
                            var segModel = SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig()
                            segModel.model = segModelPath
                            var segConfig = SherpaOnnxOfflineSpeakerSegmentationModelConfig()
                            segConfig.pyannote = segModel
                            segConfig.num_threads = config.numThreads
                            segConfig.debug = 0
                            segConfig.provider = providerCStr
                            cConfig.segmentation = segConfig

                            // embedding — 重模型 (37.7MB)，限制最多 2 线程
                            var embConfig = SherpaOnnxSpeakerEmbeddingExtractorConfig()
                            embConfig.model = embModelPath
                            embConfig.num_threads = min(config.numThreads, 2)
                            embConfig.debug = 0
                            embConfig.provider = providerCStr
                            cConfig.embedding = embConfig

                            // clustering
                            var clustConfig = SherpaOnnxFastClusteringConfig()
                            clustConfig.num_clusters = config.clustering.numClusters
                            clustConfig.threshold = config.clustering.threshold
                            cConfig.clustering = clustConfig

                            // durations
                            cConfig.min_duration_on = config.minDurationOn
                            cConfig.min_duration_off = config.minDurationOff

                            guard let sd = SherpaOnnxCreateOfflineSpeakerDiarization(&cConfig) else {
                                throw SherpaError.initializationFailed("创建分离器失败 (provider=\(provider))")
                            }

                            self.handle = sd
                            self.sampleRate = SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(sd)
                            AppLog.info("[SherpaOnnx] diarizer created with provider=\(provider)")
                        }
                        return  // 成功，跳出循环
                    } catch {
                        lastError = error
                        AppLog.warn("[SherpaOnnx] provider=\(provider) failed, trying next...")
                    }
                }
                if self.handle == nil, let err = lastError {
                    throw err
                }
            }
        }
    }

    /// 运行分离（完整音频）
    func process(samples: [Float], progress: ((Float) -> Void)? = nil) throws -> SherpaDiarizationResult {
        guard let sd = handle else {
            throw SherpaError.notInitialized
        }

        var cSamples = samples  // sherpa-onnx C API 需要可变指针，这里必须拷贝
        let n = Int32(cSamples.count)
        defer { cSamples.removeAll() }  // 返回前立即释放拷贝内存

        let resultPtr: OpaquePointer?

        if let progress = progress {
            let ctx = ProgressContext(progress: progress)
            let unmanaged = Unmanaged.passUnretained(ctx).toOpaque()
            resultPtr = SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(
                sd, &cSamples, n, { numProcessed, numTotal, arg in
                    guard let arg = arg else { return 0 }
                    let ctx = Unmanaged<ProgressContext>.fromOpaque(arg).takeUnretainedValue()
                    if numTotal > 0 {
                        ctx.progress(Float(numProcessed) / Float(numTotal))
                    }
                    return 0
                }, unmanaged
            )
        } else {
            resultPtr = SherpaOnnxOfflineSpeakerDiarizationProcess(sd, &cSamples, n)
        }

        guard let result = resultPtr else {
            throw SherpaError.processingFailed("分离处理失败")
        }

        let numSpeakers = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSpeakers(result)
        let numSegments = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result)

        var segments: [SherpaDiarizationSegment] = []
        if numSegments > 0,
           let sorted = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) {
            let count = Int(numSegments)
            for i in 0..<count {
                let seg = sorted.advanced(by: i).pointee
                segments.append(SherpaDiarizationSegment(
                    start: seg.start,
                    end: seg.end,
                    speaker: seg.speaker
                ))
            }
            SherpaOnnxOfflineSpeakerDiarizationDestroySegment(sorted)
        }

        SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result)

        return SherpaDiarizationResult(
            numSpeakers: numSpeakers,
            segments: segments,
            sampleRate: sampleRate
        )
    }

    /// 更新聚类配置（不重建分离器）
    func updateClustering(_ clustering: SherpaClusteringConfig) {
        guard let sd = handle else { return }

        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineSpeakerDiarizationConfig>.size)
        config.clustering.num_clusters = clustering.numClusters
        config.clustering.threshold = clustering.threshold

        SherpaOnnxOfflineSpeakerDiarizationSetConfig(sd, &config)
    }

    /// 获取采样率
    func getSampleRate() -> Int32 {
        return sampleRate
    }

    /// 销毁分离器
    func destroy() {
        if let sd = handle {
            SherpaOnnxDestroyOfflineSpeakerDiarization(sd)
            handle = nil
        }
    }

    deinit {
        destroy()
    }
}

// MARK: - Progress Context

private final class ProgressContext {
    let progress: (Float) -> Void
    init(progress: @escaping (Float) -> Void) {
        self.progress = progress
    }
}

// MARK: - Errors

enum SherpaError: LocalizedError {
    case modelNotFound(String)
    case initializationFailed(String)
    case notInitialized
    case processingFailed(String)
    case audioLoadFailed(String)
    case resampleFailed(String)
    case embeddingFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let msg): return "模型未找到: \(msg)"
        case .initializationFailed(let msg): return "初始化失败: \(msg)"
        case .notInitialized: return "分离器未初始化"
        case .processingFailed(let msg): return "处理失败: \(msg)"
        case .audioLoadFailed(let msg): return "音频加载失败: \(msg)"
        case .resampleFailed(let msg): return "重采样失败: \(msg)"
        case .embeddingFailed(let msg): return "声纹提取失败: \(msg)"
        }
    }
}

// MARK: - Speaker Embedding Extractor

/// 独立声纹提取器（用于实时片段级匹配）
final class SherpaOnnxEmbeddingExtractor {
    private var handle: OpaquePointer?
    private var dim: Int32 = 0

    var dimension: Int32 { dim }

    func create(modelPath: String, numThreads: Int32 = 1) throws {
        destroy()
        
        try modelPath.withCString { modelCStr in
            try "cpu".withCString { providerCStr in
                var config = SherpaOnnxSpeakerEmbeddingExtractorConfig()
                memset(&config, 0, MemoryLayout<SherpaOnnxSpeakerEmbeddingExtractorConfig>.size)
                config.model = modelCStr
                config.num_threads = numThreads
                config.debug = 0
                config.provider = providerCStr

                guard let ex = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config) else {
                    throw SherpaError.initializationFailed("创建声纹提取器失败")
                }
                self.handle = ex
                self.dim = SherpaOnnxSpeakerEmbeddingExtractorDim(ex)
            }
        }
    }

    func extractEmbedding(samples: [Float], sampleRate: Int32 = 16000) throws -> [Float] {
        guard let ex = handle else {
            throw SherpaError.notInitialized
        }
        guard !samples.isEmpty else {
            throw SherpaError.embeddingFailed("音频为空")
        }

        let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(ex)
        defer { SherpaOnnxDestroyOnlineStream(stream) }

        var cSamples = samples  // sherpa-onnx C API 需要可变指针
        let n = Int32(cSamples.count)
        defer { cSamples.removeAll() }  // 返回前立即释放拷贝内存
        SherpaOnnxOnlineStreamAcceptWaveform(stream, sampleRate, &cSamples, n)
        SherpaOnnxOnlineStreamInputFinished(stream)

        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(ex, stream) == 1 else {
            throw SherpaError.embeddingFailed("音频不足，无法提取声纹")
        }

        let rawPtr = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(ex, stream)
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(rawPtr) }

        let embedding = Array(UnsafeBufferPointer(start: rawPtr, count: Int(dim)))
        return embedding
    }

    func destroy() {
        if let ex = handle {
            SherpaOnnxDestroySpeakerEmbeddingExtractor(ex)
            handle = nil
        }
    }

    deinit {
        destroy()
    }
}
