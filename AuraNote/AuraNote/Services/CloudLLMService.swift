import Foundation

/// 云端大模型调用错误类型
enum CloudLLMError: LocalizedError {
    case emptyAPIKey
    case invalidURL(String)
    case unauthorized(String)
    case rateLimited(String)
    case serverError(Int, String)
    case networkError(String)
    case parseError(String)
    case timeout
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyAPIKey:
            return "API Key 为空，请先在系统配置中输入 API Key"
        case .invalidURL(let url):
            return "API URL 无效: \(url)"
        case .unauthorized(let msg):
            return "认证失败 (401): API Key 无效或未授权。\(msg)"
        case .rateLimited(let msg):
            return "请求受限或额度不足 (429): \(msg)"
        case .serverError(let code, let msg):
            return "云端服务异常 (HTTP \(code)): \(msg)"
        case .networkError(let msg):
            return "网络连接失败: \(msg)"
        case .parseError(let msg):
            return "解析云端返回数据失败: \(msg)"
        case .timeout:
            return "请求超时，请检查网络后重试"
        case .emptyResponse:
            return "云端模型未返回有效内容"
        }
    }
}

/// 云端大模型网络交互服务单例
final class CloudLLMService {
    static let shared = CloudLLMService()

    private var urlSession: URLSession
    private let isCustomSession: Bool

    init(session: URLSession? = nil) {
        if let s = session {
            self.urlSession = s
            self.isCustomSession = true
        } else {
            self.isCustomSession = false
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 120
            NetworkProxyManager.shared.applyProxy(
                to: config,
                proxyString: SettingsManager.shared.customProxyURL,
                isEnabled: SettingsManager.shared.isCustomProxyEnabled
            )
            self.urlSession = URLSession(configuration: config)
        }
    }

    /// 热重载会话配置（应用代理变更）
    func reloadSession() {
        guard !isCustomSession else { return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        NetworkProxyManager.shared.applyProxy(
            to: config,
            proxyString: SettingsManager.shared.customProxyURL,
            isEnabled: SettingsManager.shared.isCustomProxyEnabled
        )
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - 请求与响应数据结构

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double?
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let role: String?
                let content: String?
            }
            let message: Message?
        }
        struct ErrorDetail: Decodable {
            let message: String?
            let type: String?
            let code: String?
        }
        let choices: [Choice]?
        let error: ErrorDetail?
    }

    // MARK: - 公开业务接口

    /// 测试云端模型连接连通性
    /// - Parameters:
    ///   - model: 云端模型实体
    ///   - apiKey: 用户输入的 API-Key
    /// - Returns: 连接成功时的简要回复
    func testConnection(model: CloudModel, apiKey: String) async throws -> String {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw CloudLLMError.emptyAPIKey
        }

        AppLog.info("[CloudLLM] 开始测试连接: model=\(model.name), key=\(KeychainHelper.maskedKey(cleanKey)), url=\(model.apiURL)")

        let messages = [
            ChatRequest.Message(role: "user", content: "请回复一句：AuraNote 云端模型连接测试成功。")
        ]

        let reply = try await sendChatRequest(
            apiURL: model.apiURL,
            modelName: model.modelName,
            apiKey: cleanKey,
            messages: messages,
            temperature: 0.1
        )

        AppLog.info("[CloudLLM] 连接测试通过: \(reply)")
        return reply
    }

    /// 根据会议转写文本生成会议纪要
    /// - Parameters:
    ///   - transcript: 会议转写内容（多发言人分段）
    ///   - model: 云端模型实体
    ///   - apiKey: API-Key
    ///   - systemPrompt: 系统提示词
    /// - Returns: 整理后的结构化会议纪要
    func generateSummary(
        transcript: String,
        model: CloudModel,
        apiKey: String,
        systemPrompt: String? = nil
    ) async throws -> String {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw CloudLLMError.emptyAPIKey
        }

        let defaultPrompt = "你是一个专业的会议纪要整理助手。请将以下会议发言记录整理成结构化的会议纪要，包括：\n1. 会议概要\n2. 主要议题\n3. 决策事项\n4. 待办事项"
        let prompt = systemPrompt ?? defaultPrompt
        let messages = [
            ChatRequest.Message(role: "system", content: prompt),
            ChatRequest.Message(role: "user", content: "以下是本次会议的发言记录：\n\n\(transcript)")
        ]

        AppLog.info("[CloudLLM] 开始生成会议纪要: model=\(model.name), 转写字数=\(transcript.count)")

        let summary = try await sendChatRequest(
            apiURL: model.apiURL,
            modelName: model.modelName,
            apiKey: cleanKey,
            messages: messages,
            temperature: 0.3
        )

        AppLog.info("[CloudLLM] 会议纪要生成成功，纪要字数=\(summary.count)")
        return summary
    }

    // MARK: - 底层 HTTP 调用

    private func sendChatRequest(
        apiURL: String,
        modelName: String,
        apiKey: String,
        messages: [ChatRequest.Message],
        temperature: Double?
    ) async throws -> String {
        guard let url = URL(string: apiURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil, url.host != nil else {
            throw CloudLLMError.invalidURL(apiURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://github.com/EastlakeStudio/AuraNote", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("AuraNote", forHTTPHeaderField: "X-Title")

        let chatPayload = ChatRequest(
            model: modelName,
            messages: messages,
            temperature: temperature
        )

        do {
            request.httpBody = try JSONEncoder().encode(chatPayload)
        } catch {
            throw CloudLLMError.parseError("请求数据打包失败: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let err as URLError {
            if err.code == .timedOut {
                throw CloudLLMError.timeout
            }
            throw CloudLLMError.networkError(err.localizedDescription)
        } catch {
            throw CloudLLMError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudLLMError.parseError("未收到有效的 HTTP 响应")
        }

        // 错误状态码解析
        if httpResponse.statusCode != 200 {
            let errorMsg = extractErrorMessage(from: data)
            switch httpResponse.statusCode {
            case 401:
                throw CloudLLMError.unauthorized(errorMsg)
            case 429:
                throw CloudLLMError.rateLimited(errorMsg)
            default:
                throw CloudLLMError.serverError(httpResponse.statusCode, errorMsg)
            }
        }

        // 解析成功响应
        do {
            let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
            if let content = chatResponse.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
               !content.isEmpty {
                return content
            }
            if let err = chatResponse.error?.message {
                throw CloudLLMError.serverError(httpResponse.statusCode, err)
            }
            throw CloudLLMError.emptyResponse
        } catch let err as CloudLLMError {
            throw err
        } catch {
            // 如果不是标准 JSON 结构，尝试直接作为纯文本解析
            if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            throw CloudLLMError.parseError("响应解析失败: \(error.localizedDescription)")
        }
    }

    private func extractErrorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
           let msg = decoded.error?.message {
            return msg
        }
        if let str = String(data: data, encoding: .utf8), !str.isEmpty {
            return str
        }
        return "未知错误"
    }
}
