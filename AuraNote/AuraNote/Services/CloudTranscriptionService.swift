import Foundation

/// 云端语音转写服务异常类型
enum CloudTranscriptionError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidURL(String)
    case unsupportedAudioProtocol(String)
    case httpError(statusCode: Int, message: String)
    case decodingError(String)
    case networkError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "未配置该模型的 API-KEY，请在「系统配置」中输入"
        case .invalidURL(let url):
            return "无效的 API 端点地址: \(url)"
        case .unsupportedAudioProtocol(let p):
            return "暂不支持的音频转写协议: \(p)"
        case .httpError(let code, let msg):
            switch code {
            case 401:
                return "API-KEY 鉴权失败 (401)，请检查 Key 是否有效"
            case 403:
                return "访问被拒绝 (403)，请检查账号权限或配额"
            case 429:
                return "请求频次超限 (429)，请稍后再试或检查模型限流"
            default:
                return "云端接口错误 (状态码 \(code)): \(msg)"
            }
        case .decodingError(let detail):
            return "解析云端转写响应失败: \(detail)"
        case .networkError(let detail):
            return "网络请求异常: \(detail)"
        case .emptyResponse:
            return "云端模型未返回有效的转写文本"
        }
    }
}

/// 云端多模态大模型返回的带说话人角色的转写句子（支持重叠抢话多行化）
struct CloudDiarizedSentence: Codable, Equatable {
    let speaker: String
    let text: String
}

/// 云端语音大模型转写服务
/// 支持多模态 Chat Completions（input_audio）与标准 OpenAI Audio Transcriptions 接口
/// 具备端到端多角色分离（Diarization）与抢话多文字流还原能力
actor CloudTranscriptionService {
    static let shared = CloudTranscriptionService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - 公开转写方法

    /// 对 Float32 采样点切片进行云端语音识别
    /// - Parameters:
    ///   - samples: 16kHz Float32 PCM 采样点
    ///   - sampleRate: 采样率（默认 16000）
    ///   - hotwords: 热词或上下文提示
    ///   - model: 目标云端模型
    ///   - apiKey: API-KEY 凭证
    /// - Returns: 转写出的纯文本（包含标点）
    func transcribeSamples(
        samples: [Float],
        sampleRate: Int = 16000,
        hotwords: String = "",
        model: CloudModel,
        apiKey: String
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }

        // 短于 0.2s 的微小片段直接忽略，避免向云端发送空包
        let duration = Double(samples.count) / Double(sampleRate)
        guard duration >= 0.2 else {
            return ""
        }

        let endpointType = model.audioEndpointType ?? .chatAudio
        switch endpointType {
        case .chatAudio:
            let base64Audio = WAVDataEncoder.encodeToBase64WAV(samples: samples, sampleRate: sampleRate)
            return try await sendChatAudioRequest(
                base64Audio: base64Audio,
                hotwords: hotwords,
                model: model,
                apiKey: apiKey
            )
        case .audioTranscriptions:
            let wavData = WAVDataEncoder.encodeToWAVData(samples: samples, sampleRate: sampleRate)
            return try await sendMultipartTranscriptionRequest(
                wavData: wavData,
                hotwords: hotwords,
                model: model,
                apiKey: apiKey
            )
        }
    }

    /// 对本地音频文件进行云端转写
    func transcribeAudioFile(
        fileURL: URL,
        hotwords: String = "",
        model: CloudModel,
        apiKey: String
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }

        let audioData = try Data(contentsOf: fileURL)
        let endpointType = model.audioEndpointType ?? .chatAudio

        switch endpointType {
        case .chatAudio:
            let base64Audio = audioData.base64EncodedString()
            return try await sendChatAudioRequest(
                base64Audio: base64Audio,
                hotwords: hotwords,
                model: model,
                apiKey: apiKey
            )
        case .audioTranscriptions:
            return try await sendMultipartTranscriptionRequest(
                wavData: audioData,
                hotwords: hotwords,
                model: model,
                apiKey: apiKey
            )
        }
    }

    /// 测试云端语音转写连通性（使用 1 秒静音包）
    func testAudioConnection(
        model: CloudModel,
        apiKey: String
    ) async -> (success: Bool, message: String) {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "请先输入 API-KEY")
        }

        do {
            let testSamples = [Float](repeating: 0.0, count: 16000)
            _ = try await transcribeSamples(
                samples: testSamples,
                sampleRate: 16000,
                hotwords: "测试",
                model: model,
                apiKey: apiKey
            )
            return (true, "语音转写接口连通成功！")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - 协议一：多模态 Chat Completions (input_audio)

    private func sendChatAudioRequest(
        base64Audio: String,
        hotwords: String,
        model: CloudModel,
        apiKey: String
    ) async throws -> String {
        guard let url = URL(string: model.apiURL) else {
            throw CloudTranscriptionError.invalidURL(model.apiURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        // OpenRouter 特殊 Headers
        if model.provider.lowercased().contains("openrouter") || model.apiURL.contains("openrouter.ai") {
            request.setValue("https://github.com/EastlakeStudio/AuraNote", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("AuraNote", forHTTPHeaderField: "X-Title")
        }

        var userPrompt = "请转写这段音频为纯文本："
        if !hotwords.isEmpty {
            userPrompt += "（提示热词/上下文: \(hotwords)）"
        }

        let systemPrompt = "你是一个专业的高精度语音转写引擎。请将用户提供的音频逐字、准确地转写为文本，保持说话人的原始表达，自动补充正确的标点符号。请直接输出识别到的文本内容，不要输出任何开场白、总结、解释或代码包裹块。如果音频完全无有效人声，请输出空文本。"

        let payload: [String: Any] = [
            "model": model.modelName,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": userPrompt
                        ],
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": base64Audio,
                                "format": "wav"
                            ]
                        ]
                    ]
                ]
            ],
            "temperature": 0.1
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudTranscriptionError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.networkError("未能获取有效的 HTTP 响应")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw CloudTranscriptionError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        // 解析 Chat Completions 响应结构
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            // 有些模型音频无说话人时 content 可能为空字符串或 null，视为合法空转写
            return ""
        }

        return cleanTranscribedText(content)
    }

    // MARK: - 协议二：标准 OpenAI Audio Transcriptions (multipart/form-data)

    private func sendMultipartTranscriptionRequest(
        wavData: Data,
        hotwords: String,
        model: CloudModel,
        apiKey: String
    ) async throws -> String {
        guard let url = URL(string: model.apiURL) else {
            throw CloudTranscriptionError.invalidURL(model.apiURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // 1. model 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model.modelName)\r\n".data(using: .utf8)!)

        // 2. prompt 热词字段（如有）
        if !hotwords.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(hotwords)\r\n".data(using: .utf8)!)
        }

        // 3. file 音频文件
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        // 结束 boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudTranscriptionError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.networkError("未能获取有效的 HTTP 响应")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw CloudTranscriptionError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw CloudTranscriptionError.decodingError("返回数据中未包含 text 字段")
        }

        return cleanTranscribedText(text)
    }

    /// 清理大模型可能夹带的冗余标头或代码块包装
    private func cleanTranscribedText(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") && cleaned.hasSuffix("```") {
            let lines = cleaned.components(separatedBy: "\n")
            if lines.count >= 2 {
                cleaned = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return cleaned
    }

    // MARK: - 协议三：端到端多模态声纹分离与转写（支持多人抢话多轨还原）

    /// 对 Float32 采样点切片进行端到端多模态语音转写与说话人角色分离
    /// - Parameters:
    ///   - samples: 16kHz Float32 PCM 采样点
    ///   - sampleRate: 采样率（默认 16000）
    ///   - contextSpeakers: 已知参会人/说话人名单（用于引导大模型人名归纳）
    ///   - priorSpeaker: 上一句活跃说话人（用于长程连续性记忆）
    ///   - model: 目标云端模型（如 Gemini 3.5 Transcribe）
    ///   - apiKey: API-KEY 凭证
    /// - Returns: 结构化对话句子数组（若出现抢话或多人轮替，返回多条带各自角色的记录）
    func transcribeAndDiarizeSamples(
        samples: [Float],
        sampleRate: Int = 16000,
        contextSpeakers: [String] = [],
        priorSpeaker: String? = nil,
        model: CloudModel,
        apiKey: String
    ) async throws -> [CloudDiarizedSentence] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }

        let duration = Double(samples.count) / Double(sampleRate)
        guard duration >= 0.2 else {
            return []
        }

        let base64Audio = WAVDataEncoder.encodeToBase64WAV(samples: samples, sampleRate: sampleRate)
        return try await sendDiarizedChatAudioRequest(
            base64Audio: base64Audio,
            contextSpeakers: contextSpeakers,
            priorSpeaker: priorSpeaker,
            model: model,
            apiKey: apiKey
        )
    }

    private func sendDiarizedChatAudioRequest(
        base64Audio: String,
        contextSpeakers: [String],
        priorSpeaker: String?,
        model: CloudModel,
        apiKey: String
    ) async throws -> [CloudDiarizedSentence] {
        guard let url = URL(string: model.apiURL) else {
            throw CloudTranscriptionError.invalidURL(model.apiURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        if model.provider.lowercased().contains("openrouter") || model.apiURL.contains("openrouter.ai") {
            request.setValue("https://github.com/EastlakeStudio/AuraNote", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("AuraNote", forHTTPHeaderField: "X-Title")
        }

        var systemPrompt = """
        你是一个支持重叠抢话分离的高精度端到端多模态语音识别与说话人分离大模型。
        请仔细辨听输入音频中的每一位说话人。如果出现单人发言、多人快速轮流发言或重叠抢话，请准确区分说话人并分别转写其发言内容。

        必须严格以标准的 JSON 数组格式输出，不要输出任何 markdown 格式代码块（如 ```json），不要输出任何解释或前缀：
        [
          {"speaker": "说话人姓名或编号", "text": "说话人所说的完整内容，包含正确标点"}
        ]
        如果音频中完全没有有效人声（仅为杂音或静音），输出空数组 []。
        """

        if !contextSpeakers.isEmpty {
            systemPrompt += "\n已知参会人/说话人名单：[\(contextSpeakers.joined(separator: ", "))]，如音色与逻辑吻合，请优先对应上述人员。"
        }
        if let prior = priorSpeaker, !prior.isEmpty {
            systemPrompt += "\n上一句活跃发言人是：\(prior)，供连贯性参考。"
        }

        let payload: [String: Any] = [
            "model": model.modelName,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": "请以 JSON 格式输出当前音频中所有说话人的对话内容："
                        ],
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": base64Audio,
                                "format": "wav"
                            ]
                        ]
                    ]
                ]
            ],
            "temperature": 0.1
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudTranscriptionError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.networkError("未能获取有效的 HTTP 响应")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw CloudTranscriptionError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return []
        }

        return parseDiarizedSentences(content: content, fallbackSpeaker: priorSpeaker ?? "Speaker_1")
    }

    /// 解析大模型返回的内容为结构化对话句子（支持 JSON 数组与纯文本降级容错）
    func parseDiarizedSentences(content: String, fallbackSpeaker: String) -> [CloudDiarizedSentence] {
        var raw = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥离可能存在的 markdown 包裹
        if raw.hasPrefix("```") {
            let lines = raw.components(separatedBy: "\n")
            if lines.count >= 2 {
                let inner = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                raw = inner
            }
        }

        // 尝试从字符串中截取 [ 到 ] 的 JSON 部分
        if let startRange = raw.range(of: "["),
           let endRange = raw.range(of: "]", options: .backwards),
           startRange.lowerBound <= endRange.upperBound {
            let jsonSubstring = String(raw[startRange.lowerBound..<endRange.upperBound])
            if let jsonData = jsonSubstring.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([CloudDiarizedSentence].self, from: jsonData) {
                return decoded.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
        }

        // 容错降级：如果模型没有返回 JSON 而是返回了纯文本（如 "张三: 大家好"）
        if raw.isEmpty || raw == "[]" {
            return []
        }

        // 检查是否有按行区分说话人的模式（如 "张三: xxx\n李四: yyy"）
        let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var parsedLines: [CloudDiarizedSentence] = []
        for line in lines {
            if let colonIdx = line.firstIndex(of: "：") ?? line.firstIndex(of: ":") {
                let spk = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let txt = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                if !txt.isEmpty {
                    parsedLines.append(CloudDiarizedSentence(speaker: spk, text: txt))
                }
            }
        }
        if !parsedLines.isEmpty {
            return parsedLines
        }

        // 终极兜底：单句纯文本直接赋予 fallbackSpeaker
        return [CloudDiarizedSentence(speaker: fallbackSpeaker, text: raw)]
    }
}
