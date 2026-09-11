import Foundation
import Observation

@Observable
final class SettingsManager {
    static let shared = SettingsManager()
    static let settingsDidChangeNotification = Notification.Name("AuraNoteSettingsDidChange")
    static let downloadStateDidChangeNotification = Notification.Name("AuraNoteDownloadStateDidChange")
    static let engineDidChangeNotification = Notification.Name("AuraNoteEngineDidChange")
    static let localModelStatusDidChangeNotification = Notification.Name("AuraNoteLocalModelStatusDidChange")
    static let proxyDidChangeNotification = Notification.Name("AuraNoteProxyDidChange")
    
    var defaults: UserDefaults = .standard
    
    var llmURL: String = ""
    var llmToken: String = ""
    var llmModel: String = ""
    var summaryPromptZH: String = ""
    var summaryPromptEN: String = ""
    var langSetting: String = "" {
        didSet {
            defaults.set(langSetting, forKey: "ui_language")
            NotificationCenter.default.post(name: SettingsManager.settingsDidChangeNotification, object: nil)
        }
    }
    var hotwords: String = "" {
        didSet {
            defaults.set(hotwords, forKey: "algo_hotwords")
        }
    }
    var hotwordsScore: Float = 1.5 {
        didSet {
            defaults.set(hotwordsScore, forKey: "algo_hotwords_score")
        }
    }
    /// 模型存储基路径（固定为沙盒 Documents，不可配置）
    var modelPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
    }
    var selectedVoice: String = "openai/whisper-large-v3-turbo"
    
    // MARK: - 音频与算法参数（系统配置栏可调）
    
    /// 静音振幅阈值 (RMS)，低于此值视为无声。范围 0.0~0.1
    var silenceThreshold: Float = 0.02 {
        didSet { defaults.set(silenceThreshold, forKey: "algo_silence_threshold") }
    }
    /// 无声持续此秒数后认为说话结束，触发文本固化。范围 0.5~5.0
    var pauseWindow: Double = 1.0 {
        didSet { defaults.set(pauseWindow, forKey: "algo_pause_window") }
    }
    /// 实时转写轮询间隔（秒）。范围 0.5~5.0
    var liveTranscribeInterval: Double = 1.5 {
        didSet { defaults.set(liveTranscribeInterval, forKey: "algo_live_transcribe_interval") }
    }
    /// 语音增强：低于此峰值视为静音/噪声，不做增益。范围 0.0~0.01
    var noiseGate: Float = 0.002 {
        didSet { defaults.set(noiseGate, forKey: "algo_noise_gate") }
    }
    /// 语音增强：有语音时的目标峰值 (-3dBFS)。范围 0.3~0.95
    var targetPeak: Float = 0.7 {
        didSet { defaults.set(targetPeak, forKey: "algo_target_peak") }
    }
    /// 语音增强：最大增益倍数。范围 1.0~30.0
    var maxGain: Float = 30.0 {
        didSet { defaults.set(maxGain, forKey: "algo_max_gain") }
    }
    /// 语音增强：中高电平语音的基础增益。范围 1.0~5.0
    var baseGain: Float = 1.5 {
        didSet { defaults.set(baseGain, forKey: "algo_base_gain") }
    }
    /// 声纹聚类距离阈值（sherpa-onnx FastClustering，余弦距离 0~2）：越低越细分，说话人越多。默认 0.71
    var clusteringThreshold: Double = 0.71 {
        didSet { defaults.set(clusteringThreshold, forKey: "sherpa_cluster_dist") }
    }
    /// 增量聚类距离阈值（逐段，余弦距离 0~2）：0.45
    var incrementalClusteringDistance: Float = 0.45 {
        didSet { defaults.set(incrementalClusteringDistance, forKey: "algo_incremental_cluster_dist") }
    }
    /// 聚类级合并距离阈值（簇质心互比，余弦距离 0~2）：0.45
    var clusterMergeDistance: Float = 0.45 {
        didSet { defaults.set(clusterMergeDistance, forKey: "algo_cluster_merge_dist") }
    }
    /// 最短语音段（秒），sherpa-onnx diarization。范围 0.1~2.0。降低可保留更短的发言片段
    var minDurationOn: Float = 0.3 {
        didSet { defaults.set(minDurationOn, forKey: "sherpa_min_duration_on") }
    }
    /// 最短静音间隔（秒），sherpa-onnx diarization。范围 0.1~2.0。降低可检测更短的说话人切换停顿
    var minDurationOff: Float = 0.2 {
        didSet { defaults.set(minDurationOff, forKey: "sherpa_min_duration_off") }
    }
    /// refineWithEmbeddingSplit 句内拆分阈值（余弦距离 0~2）。低于此值认为前后半段声纹差异显著，触发拆分。范围 0.2~0.7
    var embeddingSplitThreshold: Float = 0.40 {
        didSet { defaults.set(embeddingSplitThreshold, forKey: "algo_embedding_split_threshold") }
    }
    /// 声纹匹配基础阈值（余弦相似度最低分）。范围 0.3~0.9
    var matchingThreshold: Float = 0.55 {
        didSet { defaults.set(matchingThreshold, forKey: "algo_matching_threshold") }
    }
    /// 声纹匹配高置信度阈值，高于此值自动绑定。范围 0.5~0.95
    var highConfidenceThreshold: Float = 0.60 {
        didSet { defaults.set(highConfidenceThreshold, forKey: "algo_high_confidence_threshold") }
    }
    /// 实时录音声纹匹配阈值（与离线共用同一管线，默认同 matchingThreshold）。范围 0.3~0.8
    var liveMatchingThreshold: Float = 0.58 {
        didSet { defaults.set(liveMatchingThreshold, forKey: "algo_live_matching_threshold") }
    }
    /// 离线转写消费者轮询间隔（秒）。范围 0.1~1.0
    var consumerPollInterval: Double = 0.3 {
        didSet { defaults.set(consumerPollInterval, forKey: "algo_consumer_poll_interval") }
    }
    /// 实时录音单段最大时长（秒），超过强制切分。范围 3.0~20.0
    var maxChunkDuration: Double = 30.0 {
        didSet { defaults.set(maxChunkDuration, forKey: "algo_max_chunk_duration") }
    }
    /// VAD (语音活动检测) 阈值。范围 0.05~0.5，越低越敏感。
    var vadThreshold: Float = 0.25 {
        didSet { defaults.set(vadThreshold, forKey: "algo_vad_threshold") }
    }
    
    // MARK: - FunASR 模型路径
    
    /// Bundle 内置模型根目录
    private var funasrBundleBase: String {
        guard let rp = Bundle.main.resourcePath else { return "" }
        return rp + "/sherpa-onnx-models/funasr"
    }
    
    /// 优先取 Bundle 内置模型，不存在则回退沙盒下载目录
    private func funasrDir(_ subpath: String) -> String {
        let bundleDir = funasrBundleBase + "/" + subpath
        if !funasrBundleBase.isEmpty, FileManager.default.fileExists(atPath: bundleDir) {
            return bundleDir
        }
        return modelPath + "/models/funasr/" + subpath
    }
    
    private static let paraformerModelName = "sherpa-onnx-paraformer-zh-2024-03-09"

    /// FunASR Paraformer 模型目录（实时伪流式 + 离线高精度共用）
    /// 优先返回包含 fp32 模型的目录（沙盒下载或 Bundle 内置），回退到 Bundle int8
    var funasrOfflineModelDir: String {
        let sandboxDir = modelPath + "/models/funasr/" + Self.paraformerModelName
        let sandboxFp32 = sandboxDir + "/model.onnx"
        let sandboxTokens = sandboxDir + "/tokens.txt"
        if FileManager.default.fileExists(atPath: sandboxFp32),
           FileManager.default.fileExists(atPath: sandboxTokens) {
            return sandboxDir
        }
        return funasrDir(Self.paraformerModelName)
    }

    /// FunASR Paraformer 模型文件路径，优先使用 fp32（带 token 时间戳），回退 int8
    var funasrOfflineModelPath: String {
        let dir = funasrOfflineModelDir
        let fp32 = dir + "/model.onnx"
        if FileManager.default.fileExists(atPath: fp32) {
            return fp32
        }
        return dir + "/model.int8.onnx"
    }
    
    /// FunASR 标点模型文件路径
    var funasrPunctModelPath: String {
        let subpath = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx"
        let bundlePath = funasrBundleBase + "/" + subpath
        if !funasrBundleBase.isEmpty, FileManager.default.fileExists(atPath: bundlePath) {
            return bundlePath
        }
        return modelPath + "/models/funasr/" + subpath
    }
    
    /// FunASR VAD 模型文件路径（Silero VAD）
    var funasrVadModelPath: String {
        let subpath = "silero-vad/silero_vad.onnx"
        let bundlePath = funasrBundleBase + "/" + subpath
        if !funasrBundleBase.isEmpty, FileManager.default.fileExists(atPath: bundlePath) {
            return bundlePath
        }
        return modelPath + "/models/funasr/" + subpath
    }
    
    /// FunASR Paraformer 模型是否已下载（兼容 int8 和 fp32）
    var isFunASROfflineAvailable: Bool {
        let dir = funasrOfflineModelDir
        let hasTokens = FileManager.default.fileExists(atPath: dir + "/tokens.txt")
        let hasInt8 = FileManager.default.fileExists(atPath: dir + "/model.int8.onnx")
        let hasFp32 = FileManager.default.fileExists(atPath: dir + "/model.onnx")
        return hasTokens && (hasInt8 || hasFp32)
    }

    /// 是否已下载 fp32 精度模型
    var isFp32ModelAvailable: Bool {
        let fp32Path = modelPath + "/models/funasr/" + Self.paraformerModelName + "/model.onnx"
        return FileManager.default.fileExists(atPath: fp32Path)
    }

    /// fp32 模型精度名称（已就绪时显示）
    var activeModelPrecision: String {
        let path = funasrOfflineModelPath
        if path.hasSuffix("model.onnx") { return "fp32" }
        if path.hasSuffix("model.int8.onnx") { return "int8" }
        return ""
    }
    
    /// FunASR 标点模型是否已下载
    var isFunASRPunctAvailable: Bool {
        return FileManager.default.fileExists(atPath: funasrPunctModelPath)
    }
    
    /// 是否使用 FunASR 替代 Whisper（默认 true，模型下载后自动生效）
    var useFunASR: Bool {
        get { defaults.object(forKey: "algo_use_funasr") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "algo_use_funasr") }
    }
    /// 语音转写引擎类型偏好（若本地 FunASR 模型未下载或已清理，自动推荐/回退至云端大模型）
    var transcriptionEngine: TranscriptionEngineType {
        get {
            if let raw = defaults.string(forKey: "transcription_engine"),
               let type = TranscriptionEngineType(rawValue: raw) {
                // 若用户原选了本地引擎，但本地模型文件已被清理/不存在，且云端就绪，自适应回退到云端
                if type == .localFunASR && !isFunASROfflineAvailable && TranscriptionEngineCoordinator.shared.isCloudTranscriptionReady {
                    return .cloudModel
                }
                return type
            }
            if TranscriptionEngineCoordinator.shared.isCloudTranscriptionReady || !isFunASROfflineAvailable {
                return .cloudModel
            }
            return .localFunASR
        }
        set {
            defaults.set(newValue.rawValue, forKey: "transcription_engine")
            NotificationCenter.default.post(name: Self.engineDidChangeNotification, object: nil)
            NotificationCenter.default.post(name: Self.settingsDidChangeNotification, object: nil)
        }
    }
    /// 选定的云端语音转写专用模型 ID（若为空则跟随通用模型）
    var cloudTranscriptionModelId: String {
        get {
            defaults.string(forKey: "cloud_transcription_model_id") ?? ""
        }
        set {
            defaults.set(newValue, forKey: "cloud_transcription_model_id")
        }
    }
    /// 是否启用调试模式（会议中显示调试按钮）
    var showDebug: Bool {
        get { defaults.object(forKey: "show_debug") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "show_debug") }
    }

    // MARK: - 网络代理设置

    /// 是否启用自定义网络代理
    var isCustomProxyEnabled: Bool {
        get { defaults.bool(forKey: "network_custom_proxy_enabled") }
        set {
            defaults.set(newValue, forKey: "network_custom_proxy_enabled")
            NotificationCenter.default.post(name: Self.proxyDidChangeNotification, object: nil)
            NotificationCenter.default.post(name: Self.settingsDidChangeNotification, object: nil)
            Task {
                await CloudTranscriptionService.shared.reloadSession()
                CloudLLMService.shared.reloadSession()
            }
        }
    }

    /// 自定义网络代理地址（如 http://127.0.0.1:7890、socks5://127.0.0.1:7890）
    var customProxyURL: String {
        get { defaults.string(forKey: "network_custom_proxy_url") ?? "http://127.0.0.1:7890" }
        set {
            defaults.set(newValue, forKey: "network_custom_proxy_url")
            NotificationCenter.default.post(name: Self.proxyDidChangeNotification, object: nil)
            NotificationCenter.default.post(name: Self.settingsDidChangeNotification, object: nil)
            Task {
                await CloudTranscriptionService.shared.reloadSession()
                CloudLLMService.shared.reloadSession()
            }
        }
    }
    
    // MARK: - 数据存储路径

    /// 数据存储目录 URL（固定为 App Sandbox Documents，不支持自定义路径）
    var dataDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    /// 唯一支持的模型
    static let supportedVoice = "openai/whisper-large-v3"
    /// 模型文件系统中的目录名（与 HuggingFace 仓库路径一致）
    static let supportedModelID = "openai_whisper-large-v3-v20240930"
    
    /// 单个模型的下载状态
    struct ModelDownloadState: Codable {
        var isDownloading = false
        var progress: Double = 0.0
        var error: String? = nil
        var isDownloaded = false
    }
    var modelDownloadStates: [String: ModelDownloadState] = [:]
    
    /// 获取指定模型的下载状态
    func downloadState(for voice: String) -> ModelDownloadState {
        return modelDownloadStates[voice] ?? ModelDownloadState()
    }
    
    /// 设置指定模型的下载状态
    func setDownloadState(_ state: ModelDownloadState, for voice: String) {
        modelDownloadStates[voice] = state
        // 显式通知视图下载状态变化，解决 @Observable 对字典变更追踪不可靠的问题
        NotificationCenter.default.post(name: Self.downloadStateDidChangeNotification, object: nil)
    }
    
    /// 当前选中模型的下载状态（便捷访问）
    var currentModelDownloading: Bool {
        downloadState(for: selectedVoice).isDownloading
    }
    var currentModelProgress: Double {
        downloadState(for: selectedVoice).progress
    }
    var currentModelError: String? {
        downloadState(for: selectedVoice).error
    }
    
    /// 正在下载的模型名称（如果有）
    var downloadingModelVoice: String {
        modelDownloadStates.first { $0.value.isDownloading }?.key ?? ""
    }
    
    /// 当前选中的转写引擎是否已准备就绪可用
    var isCurrentEngineReady: Bool {
        switch transcriptionEngine {
        case .localFunASR:
            return isFunASROfflineAvailable
        case .cloudModel:
            return TranscriptionEngineCoordinator.shared.isCloudTranscriptionReady
        }
    }

    /// 模型是否已就绪可用（兼容旧属性，根据当前激活的转写引擎返回对应可用状态）
    var isModelAvailable: Bool {
        return isCurrentEngineReady
    }

    // MARK: - fp32 模型下载

    static let fp32ModelURL = "https://huggingface.co/csukuangfj/sherpa-onnx-paraformer-zh-2024-03-09/resolve/main/model.onnx"
    static let fp32ModelMirrorURL = "https://hf-mirror.com/csukuangfj/sherpa-onnx-paraformer-zh-2024-03-09/resolve/main/model.onnx"

    var fp32DownloadProgress: Double = 0
    var isFp32Downloading: Bool = false
    var fp32DownloadError: String? = nil

    @ObservationIgnored
    private var fp32DownloadSession: URLSession?
    @ObservationIgnored
    private var fp32DownloadRetryURLs: [String] = []

    func startFp32Download(useMirror: Bool = true) {
        guard !isFp32Downloading else { return }
        isFp32Downloading = true
        fp32DownloadProgress = 0
        fp32DownloadError = nil

        let primary = useMirror ? Self.fp32ModelMirrorURL : Self.fp32ModelURL
        let fallback = useMirror ? Self.fp32ModelURL : Self.fp32ModelMirrorURL
        fp32DownloadRetryURLs = [primary, fallback]

        prepareFp32Destination()
        tryNextFp32Download()
    }

    private func prepareFp32Destination() {
        let destinationDir = modelPath + "/models/funasr/" + Self.paraformerModelName
        do {
            try FileManager.default.createDirectory(atPath: destinationDir, withIntermediateDirectories: true, attributes: nil)
            let bundleTokens = funasrBundleBase + "/" + Self.paraformerModelName + "/tokens.txt"
            if FileManager.default.fileExists(atPath: bundleTokens) {
                let destTokens = destinationDir + "/tokens.txt"
                if !FileManager.default.fileExists(atPath: destTokens) {
                    try FileManager.default.copyItem(atPath: bundleTokens, toPath: destTokens)
                }
            }
        } catch {
            AppLog.error("[Fp32DL] Failed to prepare directory: \(error)")
            fp32DownloadError = error.localizedDescription
            isFp32Downloading = false
            fp32DownloadRetryURLs = []
        }
    }

    private func tryNextFp32Download() {
        guard let urlString = fp32DownloadRetryURLs.first else {
            isFp32Downloading = false
            NotificationCenter.default.post(name: Self.downloadStateDidChangeNotification, object: nil)
            return
        }
        fp32DownloadRetryURLs.removeFirst()

        guard let url = URL(string: urlString) else {
            tryNextFp32Download()
            return
        }

        let destinationDir = modelPath + "/models/funasr/" + Self.paraformerModelName
        let destinationFile = destinationDir + "/model.onnx"
        let destinationURL = URL(fileURLWithPath: destinationFile)

        let session = URLSession(
            configuration: .default,
            delegate: Fp32DownloadDelegate(
                destinationURL: destinationURL,
                onProgress: { [weak self] p in
                    DispatchQueue.main.async {
                        self?.fp32DownloadProgress = p
                    }
                },
                onComplete: { [weak self] result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success:
                            self?.fp32DownloadProgress = 1.0
                            self?.isFp32Downloading = false
                            self?.fp32DownloadError = nil
                            self?.fp32DownloadRetryURLs = []
                            AppLog.info("[Fp32DL] Download completed, reloading model...")
                            self?.reloadFunASRModel()
                            NotificationCenter.default.post(name: Self.settingsDidChangeNotification, object: nil)
                        case .failure(let error):
                            AppLog.error("[Fp32DL] Download failed from \(urlString): \(error), retries left: \(self?.fp32DownloadRetryURLs.count ?? 0)")
                            if self?.fp32DownloadRetryURLs.isEmpty == false {
                                self?.fp32DownloadProgress = 0
                                self?.tryNextFp32Download()
                            } else {
                                self?.fp32DownloadError = error.localizedDescription
                                self?.isFp32Downloading = false
                            }
                        }
                        NotificationCenter.default.post(name: Self.downloadStateDidChangeNotification, object: nil)
                    }
                }
            ),
            delegateQueue: nil
        )
        fp32DownloadSession = session
        let task = session.downloadTask(with: url)
        task.resume()
        AppLog.info("[Fp32DL] Starting download from \(urlString)")
    }

    func cancelFp32Download() {
        fp32DownloadSession?.invalidateAndCancel()
        fp32DownloadSession = nil
        isFp32Downloading = false
        fp32DownloadProgress = 0
        fp32DownloadError = nil
        fp32DownloadRetryURLs = []
        NotificationCenter.default.post(name: Self.downloadStateDidChangeNotification, object: nil)
    }

    func removeFp32Model() {
        let dir = modelPath + "/models/funasr/" + Self.paraformerModelName
        let fp32File = dir + "/model.onnx"
        if FileManager.default.fileExists(atPath: fp32File) {
            try? FileManager.default.removeItem(atPath: fp32File)
            AppLog.info("[Fp32DL] Removed fp32 model, reloading...")
        }
        let tokensFile = dir + "/tokens.txt"
        let int8File = dir + "/model.int8.onnx"
        if FileManager.default.fileExists(atPath: tokensFile),
           !FileManager.default.fileExists(atPath: int8File) {
            try? FileManager.default.removeItem(atPath: tokensFile)
        }
        reloadFunASRModel()
        NotificationCenter.default.post(name: Self.settingsDidChangeNotification, object: nil)
    }

    /// 彻底清理本地所有已下载的 ASR 离线模型文件（释放磁盘空间，重置本地状态）
    func removeAllLocalASRModels() {
        let fm = FileManager.default
        let funasrRoot = modelPath + "/models/funasr"
        if fm.fileExists(atPath: funasrRoot) {
            try? fm.removeItem(atPath: funasrRoot)
            AppLog.info("[Settings] Removed all local FunASR models from \(funasrRoot)")
        }
        let whisperkitRoot = modelPath + "/models/argmaxinc"
        if fm.fileExists(atPath: whisperkitRoot) {
            try? fm.removeItem(atPath: whisperkitRoot)
            AppLog.info("[Settings] Removed all local WhisperKit models from \(whisperkitRoot)")
        }
        modelDownloadStates = [:]
        // 清理本地模型后，自动将首选引擎切换为云端大模型
        self.transcriptionEngine = .cloudModel
        Task {
            await FunASRService.shared.reset()
        }
        NotificationCenter.default.post(name: Self.localModelStatusDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: Self.engineDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: Self.settingsDidChangeNotification, object: nil)
    }

    /// 获取本地已下载模型总大小字符串（如 "235.4 MB" 或 "0 MB"）
    var localModelsDiskUsageString: String {
        let fm = FileManager.default
        let modelsDir = modelPath + "/models"
        guard let enumerator = fm.enumerator(atPath: modelsDir) else { return "0 MB" }
        var totalBytes: Int64 = 0
        while let element = enumerator.nextObject() as? String {
            let fullPath = modelsDir + "/" + element
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? Int64 {
                totalBytes += size
            }
        }
        let mb = Double(totalBytes) / (1024.0 * 1024.0)
        if mb >= 1024.0 {
            return String(format: "%.2f GB", mb / 1024.0)
        } else {
            return String(format: "%.1f MB", mb)
        }
    }

    /// 下载或删除 fp32 模型后，异步重载 FunASR 引擎
    private func reloadFunASRModel() {
        let newDir = funasrOfflineModelDir
        Task {
            do {
                try await FunASRService.shared.initializeOffline(modelDir: newDir)
                AppLog.info("[Fp32DL] FunASR reloaded with precision: \(self.activeModelPrecision)")
            } catch {
                AppLog.error("[Fp32DL] FunASR reload failed: \(error)")
            }
        }
    }

    var modelVersion = "" {
        didSet { if !modelVersion.isEmpty { defaults.set(modelVersion, forKey: "current_model_version") } }
    }
    
    var summaryPrompt: String {
        get {
            let activeLang = langSetting.isEmpty ? getSystemLanguage() : langSetting
            return activeLang.contains("en") ? summaryPromptEN : summaryPromptZH
        }
        set {
            let activeLang = langSetting.isEmpty ? getSystemLanguage() : langSetting
            if activeLang.contains("en") {
                summaryPromptEN = newValue
            } else {
                summaryPromptZH = newValue
            }
        }
    }
    
    var isLLMConfigured: Bool {
        return (!llmURL.isEmpty && !llmToken.isEmpty) || CloudModelManager.shared.isCurrentModelConfigured
    }
    
    /// 标记是否已完成首次启动时的文件系统同步（仅首次 load 时执行清理）
    private var hasPerformedStartupSync = false
    
    private init() {
        load()
    }
    
    func load() {
        let d = defaults
        llmURL = d.string(forKey: "llm_url") ?? ""
        // 从 Keychain 读取 token；同时兼容旧版 UserDefaults 迁移
        if let keychainToken = KeychainHelper.read(forKey: "llm_token"), !keychainToken.isEmpty {
            llmToken = keychainToken
        } else if let oldToken = d.string(forKey: "llm_token"), !oldToken.isEmpty {
            // 一次性迁移：从 UserDefaults 写入 Keychain
            KeychainHelper.save(oldToken, forKey: "llm_token")
            d.removeObject(forKey: "llm_token")
            llmToken = oldToken
        } else {
            llmToken = ""
        }
        llmModel = d.string(forKey: "llm_model") ?? "gpt-4o"
        
        let oldPrompt = d.string(forKey: "summary_prompt")
        var zhVal = d.string(forKey: "summary_prompt_zh") ?? oldPrompt ?? "你是一个专业的会议纪要整理助手。请将以下会议发言记录整理成结构化的会议纪要，包括：\n1. 会议概要\n2. 主要议题\n3. 决策事项\n4. 待办事项"
        var enVal = d.string(forKey: "summary_prompt_en") ?? "You are a professional meeting assistant. Please organize the following meeting transcript into a structured summary, including:\n1. Overview\n2. Key Topics\n3. Decisions Made\n4. Action Items"
        
        // 注意：以下中文字符串为旧版本硬编码值，用于迁移判断，不可改为 loc()
        if zhVal == "自定义提示词" || zhVal == "这是一个测试自定义提示词" {
            zhVal = "你是一个专业的会议纪要整理助手。请将以下会议发言记录整理成结构化的会议纪要，包括：\n1. 会议概要\n2. 主要议题\n3. 决策事项\n4. 待办事项"
        }
        // 注意：比较的是旧版本写入的硬编码值，不可改为 loc()
        if enVal == "自定义提示词" || enVal == "这是一个测试自定义提示词" {
            enVal = "You are a professional meeting assistant. Please organize the following meeting transcript into a structured summary, including:\n1. Overview\n2. Key Topics\n3. Decisions Made\n4. Action Items"
        }
        
        summaryPromptZH = zhVal
        summaryPromptEN = enVal
        
        langSetting = d.string(forKey: "ui_language") ?? ""
        hotwords = d.string(forKey: "algo_hotwords") ?? ""
        hotwordsScore = d.object(forKey: "algo_hotwords_score") as? Float ?? 1.5
        selectedVoice = Self.supportedVoice
        
        // 算法参数：从 UserDefaults 加载，未设置则使用默认值
        silenceThreshold = d.object(forKey: "algo_silence_threshold") as? Float ?? 0.02
        pauseWindow = d.object(forKey: "algo_pause_window") as? Double ?? 1.0
        liveTranscribeInterval = d.object(forKey: "algo_live_transcribe_interval") as? Double ?? 1.5
        noiseGate = d.object(forKey: "algo_noise_gate") as? Float ?? 0.002
        targetPeak = d.object(forKey: "algo_target_peak") as? Float ?? 0.7
        maxGain = d.object(forKey: "algo_max_gain") as? Float ?? 30.0
        baseGain = d.object(forKey: "algo_base_gain") as? Float ?? 1.5
        clusteringThreshold = d.object(forKey: "sherpa_cluster_dist") as? Double ?? 0.71
        let savedIncr = d.object(forKey: "algo_incremental_cluster_dist") as? Float
        incrementalClusteringDistance = (savedIncr == 0.36 || savedIncr == 0.28 || savedIncr == nil) ? 0.45 : savedIncr!
        let savedMerge = d.object(forKey: "algo_cluster_merge_dist") as? Float
        clusterMergeDistance = (savedMerge == 0.38 || savedMerge == 0.50 || savedMerge == 0.30 || savedMerge == nil) ? 0.45 : savedMerge!
        minDurationOn = d.object(forKey: "sherpa_min_duration_on") as? Float ?? 0.3
        minDurationOff = d.object(forKey: "sherpa_min_duration_off") as? Float ?? 0.2
        embeddingSplitThreshold = d.object(forKey: "algo_embedding_split_threshold") as? Float ?? 0.40
        let savedMatching = d.object(forKey: "algo_matching_threshold") as? Float
        matchingThreshold = (savedMatching == 0.70 || savedMatching == nil) ? 0.55 : savedMatching!
        let savedHighConf = d.object(forKey: "algo_high_confidence_threshold") as? Float
        highConfidenceThreshold = (savedHighConf == 0.75 || savedHighConf == 0.55 || savedHighConf == nil) ? 0.60 : savedHighConf!
        liveMatchingThreshold = d.object(forKey: "algo_live_matching_threshold") as? Float ?? 0.58
        AppLog.info("[Settings] clusteringThreshold=\(clusteringThreshold) incrClusterDist=\(incrementalClusteringDistance) clusterMergeDist=\(clusterMergeDistance) minOn=\(minDurationOn) minOff=\(minDurationOff) matching=\(matchingThreshold) highConf=\(highConfidenceThreshold) liveMatching=\(liveMatchingThreshold)")
        consumerPollInterval = d.object(forKey: "algo_consumer_poll_interval") as? Double ?? 0.3
        maxChunkDuration = d.object(forKey: "algo_max_chunk_duration") as? Double ?? 20.0
        vadThreshold = d.object(forKey: "algo_vad_threshold") as? Float ?? 0.25
        
        // 仅在首次启动时加载持久化的下载状态，后续使用内存中已有状态
        if !hasPerformedStartupSync {
            if let savedStatesData = d.data(forKey: "model_download_states"),
               let decoded = try? JSONDecoder().decode([String: ModelDownloadState].self, from: savedStatesData) {
                modelDownloadStates = decoded
            }
        }
        // 首次启动时与文件系统同步：以模型目录中的实际文件为准
        if !hasPerformedStartupSync {
            hasPerformedStartupSync = true
            let repoPath = modelPath + "/models/argmaxinc/whisperkit-coreml"
            let variant = Self.supportedModelID
            let modelDir = URL(fileURLWithPath: repoPath).appendingPathComponent(variant)
            let markerURL = modelDir.appendingPathComponent(".download_complete")
            let fsExists = FileManager.default.fileExists(atPath: markerURL.path)
            var state = downloadState(for: Self.supportedVoice)
            state.isDownloaded = fsExists
            // 清除残留的下载中状态（App 被杀后 Task 已消失）
            if state.isDownloading {
                state.isDownloading = false
                state.progress = 0.0
            }
            setDownloadState(state, for: Self.supportedVoice)
            // 同步后立即持久化
            if let encoded = try? JSONEncoder().encode(modelDownloadStates) {
                d.set(encoded, forKey: "model_download_states")
            }
        }
    }
    
    func save() {
        let d = defaults
        d.set(llmURL, forKey: "llm_url")
        // llmToken 存储在 Keychain 中，不写入 UserDefaults
        KeychainHelper.save(llmToken, forKey: "llm_token")
        d.set(llmModel, forKey: "llm_model")
        
        d.set(summaryPromptZH, forKey: "summary_prompt_zh")
        d.set(summaryPromptEN, forKey: "summary_prompt_en")
        // Also save to active prompt key
        d.set(summaryPrompt, forKey: "summary_prompt")
        
        d.set(langSetting, forKey: "ui_language")
        d.set(selectedVoice, forKey: "voice_model")
        
        // 持久化每模型下载状态
        if let encoded = try? JSONEncoder().encode(modelDownloadStates) {
            d.set(encoded, forKey: "model_download_states")
        }
        
        NotificationCenter.default.post(name: SettingsManager.settingsDidChangeNotification, object: nil)
    }
    
    private func getSystemLanguage() -> String {
        return Locale.preferredLanguages.first ?? "zh-Hans"
    }
}

// MARK: - fp32 模型下载代理

private final class Fp32DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destinationURL: URL
    let onProgress: (Double) -> Void
    let onComplete: (Result<URL, Error>) -> Void
    private var didFinish = false

    init(destinationURL: URL, onProgress: @escaping (Double) -> Void, onComplete: @escaping (Result<URL, Error>) -> Void) {
        self.destinationURL = destinationURL
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        didFinish = true
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            onComplete(.success(destinationURL))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error, !didFinish {
            onComplete(.failure(error))
        }
    }
}
