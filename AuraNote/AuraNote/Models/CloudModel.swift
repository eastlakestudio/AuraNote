import Foundation

/// 音频转写接口协议类型
enum AudioEndpointType: String, Codable {
    /// 多模态 Chat Completions（通过 input_audio base64 传递音频，如 Gemini, Qwen-Audio, MAI-Transcribe-2, OpenRouter）
    case chatAudio = "chat_audio"
    /// 标准音频转写端点（POST /v1/audio/transcriptions，multipart 表单上传，如 OpenAI Whisper 等）
    case audioTranscriptions = "audio_transcriptions"
}

/// 云端大模型配置实体（定义模型的元数据，不包含 API-KEY）
struct CloudModel: Identifiable, Hashable, Codable {
    /// 唯一标识，如 "deepseek-chat"
    var id: String
    /// 界面显示名称，如 "DeepSeek V3 (Chat)"
    var name: String
    /// 模型供应商标签，如 "DeepSeek", "Aliyun", "OpenAI"
    var provider: String
    /// API 端点完整 URL，如 "https://api.deepseek.com/chat/completions"
    var apiURL: String
    /// 实际传给模型接口的 model 参数名称，如 "deepseek-chat"
    var modelName: String
    /// 是否允许用户自定义端点或名称
    var isCustom: Bool?
    /// 是否支持语音转写能力
    var supportsAudio: Bool?
    /// 音频转写接口协议类型
    var audioEndpointType: AudioEndpointType?

    init(
        id: String,
        name: String,
        provider: String,
        apiURL: String,
        modelName: String,
        isCustom: Bool? = false,
        supportsAudio: Bool? = false,
        audioEndpointType: AudioEndpointType? = .chatAudio
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.apiURL = apiURL
        self.modelName = modelName
        self.isCustom = isCustom
        self.supportsAudio = supportsAudio
        self.audioEndpointType = audioEndpointType
    }

    /// 是否为自定义模型
    var isCustomConfigurable: Bool {
        isCustom ?? (id == "custom")
    }

    /// 是否支持语音转写
    var isAudioTranscribeCapable: Bool {
        supportsAudio ?? false
    }
}

