import Foundation
import Observation

/// 云端大模型配置管理单例，负责管理模型预置列表、当前选中的模型以及安全凭据绑定
@Observable
final class CloudModelManager {
    static let shared = CloudModelManager()

    static let modelSelectionDidChangeNotification = Notification.Name("CloudModelSelectionDidChange")

    var defaults: UserDefaults = .standard

    /// 所有可用云端模型列表（从 JSON 文件加载）
    var models: [CloudModel] = []

    /// 当前选中的模型 ID
    var selectedModelId: String = "" {
        didSet {
            defaults.set(selectedModelId, forKey: "cloud_selected_model_id")
            NotificationCenter.default.post(name: Self.modelSelectionDidChangeNotification, object: nil)
        }
    }

    /// 沙盒存储的 JSON 路径
    private var sandboxJSONURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("cloud_models.json")
    }

    /// 默认内置备用配置（仅在没有任何 JSON 文件时生效）
    private static let fallbackModels: [CloudModel] = [
        CloudModel(
            id: "openrouter-auto",
            name: "OpenRouter 聚合网关 (Auto / 多模型)",
            provider: "OpenRouter",
            apiURL: "https://openrouter.ai/api/v1/chat/completions",
            modelName: "openrouter/auto",
            supportsAudio: true,
            audioEndpointType: .chatAudio
        ),
        CloudModel(
            id: "openrouter-gemini",
            name: "OpenRouter (Gemini 2.5/3.5 Flash)",
            provider: "OpenRouter",
            apiURL: "https://openrouter.ai/api/v1/chat/completions",
            modelName: "google/gemini-2.5-flash",
            supportsAudio: true,
            audioEndpointType: .chatAudio
        ),
        CloudModel(
            id: "mai-transcribe-2",
            name: "微软 MAI-Transcribe-2 (Azure AI)",
            provider: "Microsoft",
            apiURL: "https://models.inference.ai.azure.com/chat/completions",
            modelName: "MAI-Transcribe-2",
            supportsAudio: true,
            audioEndpointType: .chatAudio
        ),
        CloudModel(
            id: "gemini-transcribe",
            name: "Google Gemini 3.5 Transcribe",
            provider: "Google",
            apiURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            modelName: "gemini-2.5-flash",
            supportsAudio: true,
            audioEndpointType: .chatAudio
        ),
        CloudModel(
            id: "qwen-audio",
            name: "阿里 Qwen-Audio (通义千问音频大模型)",
            provider: "Aliyun",
            apiURL: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            modelName: "qwen-audio-chat",
            supportsAudio: true,
            audioEndpointType: .chatAudio
        ),
        CloudModel(
            id: "deepseek-chat",
            name: "DeepSeek V3 (Chat)",
            provider: "DeepSeek",
            apiURL: "https://api.deepseek.com/chat/completions",
            modelName: "deepseek-chat",
            supportsAudio: false
        ),
        CloudModel(
            id: "qwen-plus",
            name: "通义千问 Plus (Qwen-Plus)",
            provider: "Aliyun",
            apiURL: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            modelName: "qwen-plus",
            supportsAudio: false
        ),
        CloudModel(
            id: "glm-4",
            name: "智谱 GLM-4 (Zhipu AI)",
            provider: "Zhipu",
            apiURL: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            modelName: "glm-4",
            supportsAudio: false
        ),
        CloudModel(
            id: "moonshot-v1-8k",
            name: "月之暗面 Kimi (Moonshot)",
            provider: "Moonshot",
            apiURL: "https://api.moonshot.cn/v1/chat/completions",
            modelName: "moonshot-v1-8k",
            supportsAudio: false
        ),
        CloudModel(
            id: "gpt-4o",
            name: "OpenAI GPT-4o",
            provider: "OpenAI",
            apiURL: "https://api.openai.com/v1/chat/completions",
            modelName: "gpt-4o",
            supportsAudio: true,
            audioEndpointType: .chatAudio
        ),
        CloudModel(
            id: "custom",
            name: "自定义兼容模型 (Custom)",
            provider: "Custom",
            apiURL: "https://api.openai.com/v1/chat/completions",
            modelName: "custom-model",
            isCustom: true,
            supportsAudio: true,
            audioEndpointType: .chatAudio
        )
    ]

    private init() {
        load()
    }

    /// 从 JSON 文件加载云端模型列表
    func load() {
        var bundleModels: [CloudModel] = []
        if let bundleURL = Bundle.main.url(forResource: "cloud_models", withExtension: "json"),
           let data = try? Data(contentsOf: bundleURL),
           let decoded = try? JSONDecoder().decode([CloudModel].self, from: data),
           !decoded.isEmpty {
            bundleModels = decoded
        } else {
            bundleModels = Self.fallbackModels
        }

        let sandboxURL = sandboxJSONURL
        var loadedModels: [CloudModel] = []

        if FileManager.default.fileExists(atPath: sandboxURL.path),
           let data = try? Data(contentsOf: sandboxURL),
           let decoded = try? JSONDecoder().decode([CloudModel].self, from: data),
           !decoded.isEmpty {
            // 用最新的预置模型能力补齐沙盒中的旧配置
            var merged = decoded
            for i in 0..<merged.count {
                if let bm = bundleModels.first(where: { $0.id == merged[i].id }) {
                    merged[i].supportsAudio = bm.supportsAudio
                    merged[i].audioEndpointType = bm.audioEndpointType
                }
            }
            loadedModels = merged
            try? JSONEncoder().encode(loadedModels).write(to: sandboxURL)
        } else {
            loadedModels = bundleModels
            try? JSONEncoder().encode(loadedModels).write(to: sandboxURL)
        }

        self.models = loadedModels.isEmpty ? Self.fallbackModels : loadedModels

        // 加载选中的模型 ID
        let savedId = defaults.string(forKey: "cloud_selected_model_id") ?? ""
        if !savedId.isEmpty && self.models.contains(where: { $0.id == savedId }) {
            self.selectedModelId = savedId
        } else {
            self.selectedModelId = self.models.first?.id ?? "deepseek-chat"
        }
    }

    /// 保存模型配置列表到沙盒 JSON（注意：绝不包含 API-KEY）
    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(models)
            try data.write(to: sandboxJSONURL, options: .atomic)
        } catch {
            AppLog.error("[CloudModelManager] 保存云端模型 JSON 失败: \(error)")
        }
    }

    /// 当前选中的模型对象
    var selectedModel: CloudModel {
        if let found = models.first(where: { $0.id == selectedModelId }) {
            return found
        }
        return models.first ?? Self.fallbackModels[0]
    }

    /// 获取指定模型的 API Key（从系统 Keychain 读取）
    func apiKey(for modelId: String) -> String {
        KeychainHelper.readAPIKey(forModelId: modelId) ?? ""
    }

    /// 当前选中模型的 API Key
    var currentApiKey: String {
        apiKey(for: selectedModel.id)
    }

    /// 安全保存指定模型的 API Key 到 Keychain
    @discardableResult
    func saveApiKey(_ key: String, for modelId: String) -> Bool {
        let success = KeychainHelper.saveAPIKey(key, forModelId: modelId)
        if success {
            NotificationCenter.default.post(name: Self.modelSelectionDidChangeNotification, object: nil)
        }
        return success
    }

    /// 安全删除指定模型的 API Key
    @discardableResult
    func deleteApiKey(for modelId: String) -> Bool {
        let success = KeychainHelper.deleteAPIKey(forModelId: modelId)
        if success {
            NotificationCenter.default.post(name: Self.modelSelectionDidChangeNotification, object: nil)
        }
        return success
    }

    /// 当前模型是否已配置有效 API Key
    var isCurrentModelConfigured: Bool {
        !currentApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 更新模型配置（例如修改自定义模型的 URL 或名称）
    func updateModel(_ updated: CloudModel) {
        if let idx = models.firstIndex(where: { $0.id == updated.id }) {
            models[idx] = updated
            save()
        }
    }
}
