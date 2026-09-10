import Foundation

/// 语音转写引擎类型
enum TranscriptionEngineType: String, CaseIterable, Codable {
    /// 本地 FunASR 引擎（完全离线、低延迟实时上屏、保护隐私）
    case localFunASR = "local_funasr"
    /// 云端大模型转写引擎（高精度、多语言理解、需网络与 API-Key）
    case cloudModel = "cloud_model"

    var displayName: String {
        switch self {
        case .localFunASR:
            return "本地 FunASR (离线)"
        case .cloudModel:
            return "云端大模型 (高精)"
        }
    }

    var systemIcon: String {
        switch self {
        case .localFunASR:
            return "waveform.circle.fill"
        case .cloudModel:
            return "cloud.fill"
        }
    }
}

/// 转写调度辅助工具类
final class TranscriptionEngineCoordinator {
    static let shared = TranscriptionEngineCoordinator()

    private init() {}

    /// 获取当前适用的云端语音转写模型与 API-KEY
    func getActiveCloudTranscriptionModel() -> (model: CloudModel, apiKey: String)? {
        let manager = CloudModelManager.shared

        // 1. 优先检查显式配置的云端转写专用模型
        let dedicatedId = SettingsManager.shared.cloudTranscriptionModelId
        if !dedicatedId.isEmpty, let model = manager.models.first(where: { $0.id == dedicatedId && $0.isAudioTranscribeCapable }) {
            let key = manager.apiKey(for: model.id)
            if !key.isEmpty {
                return (model, key)
            }
        }

        // 2. 优先检查全局选中的模型（若支持音频且已配置 Key）
        let selected = manager.selectedModel
        if selected.isAudioTranscribeCapable {
            let key = manager.apiKey(for: selected.id)
            if !key.isEmpty {
                return (selected, key)
            }
        }

        // 3. 扫描已配置 API-Key 且支持音频的模型（优先匹配 gemini-transcribe）
        let candidateAudioModels = manager.models.filter { $0.isAudioTranscribeCapable }
        if let gemini = candidateAudioModels.first(where: { $0.id == "gemini-transcribe" }) {
            let key = manager.apiKey(for: gemini.id)
            if !key.isEmpty {
                return (gemini, key)
            }
        }

        for model in candidateAudioModels {
            let key = manager.apiKey(for: model.id)
            if !key.isEmpty {
                return (model, key)
            }
        }

        return nil
    }

    /// 检查云端转写是否已准备就绪（存在支持音频的模型且已配置 Key）
    var isCloudTranscriptionReady: Bool {
        return getActiveCloudTranscriptionModel() != nil
    }
}
