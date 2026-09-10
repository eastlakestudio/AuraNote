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
                let detail = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                return "请求频次超限 (429)\(detail.isEmpty ? "" : ": \(detail)")"
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
    /// 429 初始重试延迟（秒），测试环境可设为小值以加速执行
    var retryDelay: Double = 2.0

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 设置重试延迟（主要供单元测试使用）
    func setRetryDelay(_ delay: Double) {
        self.retryDelay = delay
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

    // MARK: - 离线长音频宏观分块转写与角色分离

    /// 离线长音频宏观分块转写与说话人分离管线
    /// - Parameters:
    ///   - samples: 16kHz 单声道 Float 采样数据
    ///   - sampleRate: 采样率 (通常为 16000)
    ///   - meetingId: 会议 ID
    ///   - contextSpeakers: 已知参会人/说话人名单
    ///   - model: 云端大模型配置
    ///   - apiKey: API Key
    ///   - windowDurationSeconds: 宏观大窗口时长（默认 50 秒）
    ///   - pacingDelaySeconds: 请求间安全节流延迟（默认 1.0 秒，控制在 10 RPM 以内，防止突破 15 RPM 限制）
    ///   - onProgress: 进度回调 (progress, processedSeconds, totalSeconds)
    ///   - onSegmentsChunk: 批次生成段时的回调（用于实时推送到 UI）
    /// - Returns: 生成的所有 TranscriptSegment
    func transcribeOfflineAudio(
        samples: [Float],
        sampleRate: Int = 16000,
        meetingId: String,
        contextSpeakers: [String] = [],
        model: CloudModel,
        apiKey: String,
        windowDurationSeconds: Double = 50.0,
        pacingDelaySeconds: Double = 1.0,
        onProgress: (@Sendable (Double, Double, Double) async -> Void)? = nil,
        onSegmentsChunk: (@Sendable ([TranscriptSegment]) async -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        guard !samples.isEmpty && sampleRate > 0 else {
            return []
        }

        let totalDuration = Double(samples.count) / Double(sampleRate)

        // 场景 1：短音频（<= 60 秒，如 30 秒测试文件），单次请求整段直出，耗时仅 2~3 秒，绝不 429
        if totalDuration <= 60.0 {
            AppLog.info("[CloudASR] Short audio (\(String(format: "%.1f", totalDuration))s <= 60s): executing single-shot end-to-end diarization")
            let sentences = try await transcribeAndDiarizeSamples(
                samples: samples,
                sampleRate: sampleRate,
                contextSpeakers: contextSpeakers,
                priorSpeaker: nil,
                model: model,
                apiKey: apiKey
            )

            var diarizedSentences = sentences
            if diarizedSentences.isEmpty {
                // 容错降级：尝试单次基础转写
                if let fallbackText = try? await transcribeSamples(
                    samples: samples,
                    sampleRate: sampleRate,
                    hotwords: "",
                    model: model,
                    apiKey: apiKey
                ), !fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    diarizedSentences = [CloudDiarizedSentence(speaker: "Speaker_1", text: fallbackText.trimmingCharacters(in: .whitespacesAndNewlines))]
                }
            }

            let segments = buildSegmentsFromSentences(
                sentences: diarizedSentences,
                windowStartSec: 0.0,
                windowEndSec: totalDuration,
                meetingId: meetingId,
                fallbackSpeaker: "Speaker_1"
            )

            if !segments.isEmpty {
                await onSegmentsChunk?(segments)
            }
            await onProgress?(1.0, totalDuration, totalDuration)
            return segments
        }

        // 场景 2：长音频（> 60 秒），采用 50 秒宏观大窗口切分，逐步渐进式处理并加节流
        let windowSamples = max(sampleRate, Int(windowDurationSeconds * Double(sampleRate)))
        let totalWindows = Int(ceil(Double(samples.count) / Double(windowSamples)))
        AppLog.info("[CloudASR] Long audio (\(String(format: "%.1f", totalDuration))s): partitioned into \(totalWindows) macro-windows (\(windowDurationSeconds)s each)")

        var allSegments: [TranscriptSegment] = []
        var lastSpeaker: String? = nil

        for windowIdx in 0..<totalWindows {
            try Task.checkCancellation()

            let startSample = windowIdx * windowSamples
            let endSample = min(samples.count, (windowIdx + 1) * windowSamples)
            guard startSample < endSample else { continue }

            let windowSlice = Array(samples[startSample..<endSample])
            let windowStartSec = Double(startSample) / Double(sampleRate)
            let windowEndSec = Double(endSample) / Double(sampleRate)

            AppLog.info("[CloudASR] Processing macro-window \(windowIdx + 1)/\(totalWindows) [\(String(format: "%.1f", windowStartSec))s - \(String(format: "%.1f", windowEndSec))s]...")

            var sentences = try await transcribeAndDiarizeSamples(
                samples: windowSlice,
                sampleRate: sampleRate,
                contextSpeakers: contextSpeakers,
                priorSpeaker: lastSpeaker,
                model: model,
                apiKey: apiKey
            )

            if sentences.isEmpty {
                if let fallbackText = try? await transcribeSamples(
                    samples: windowSlice,
                    sampleRate: sampleRate,
                    hotwords: "",
                    model: model,
                    apiKey: apiKey
                ), !fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sentences = [CloudDiarizedSentence(speaker: lastSpeaker ?? "Speaker_1", text: fallbackText.trimmingCharacters(in: .whitespacesAndNewlines))]
                }
            }

            let windowSegments = buildSegmentsFromSentences(
                sentences: sentences,
                windowStartSec: windowStartSec,
                windowEndSec: windowEndSec,
                meetingId: meetingId,
                fallbackSpeaker: lastSpeaker ?? "Speaker_1"
            )

            if let last = windowSegments.last {
                lastSpeaker = last.speakerLabel
            }

            if !windowSegments.isEmpty {
                allSegments.append(contentsOf: windowSegments)
                await onSegmentsChunk?(windowSegments)
            }

            let progress = min(1.0, windowEndSec / totalDuration)
            await onProgress?(progress, windowEndSec, totalDuration)

            // 安全节流：窗口之间等待 pacingDelaySeconds，控制请求速率
            if windowIdx < totalWindows - 1 && pacingDelaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(pacingDelaySeconds * 1_000_000_000))
            }
        }

        return allSegments
    }

    /// 将大模型结构化解析出的句子数组映射为带有起止时间的 TranscriptSegment
    private func buildSegmentsFromSentences(
        sentences: [CloudDiarizedSentence],
        windowStartSec: Double,
        windowEndSec: Double,
        meetingId: String,
        fallbackSpeaker: String
    ) -> [TranscriptSegment] {
        let validSentences = sentences.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validSentences.isEmpty else { return [] }

        let windowDuration = max(0.1, windowEndSec - windowStartSec)

        if validSentences.count == 1 {
            let item = validSentences[0]
            let spk = item.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                TranscriptSegment(
                    id: "\(meetingId)_cloud_\(UUID().uuidString)",
                    startTime: windowStartSec,
                    endTime: windowEndSec,
                    text: item.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    speakerLabel: spk.isEmpty ? fallbackSpeaker : spk,
                    isFinal: true
                )
            ]
        }

        // 多句/多人交替发言：根据字数占比在窗口时间内分配起始与终止时间
        let totalChars = max(1, validSentences.reduce(0) { $0 + max(1, $1.text.count) })
        var currentStart = windowStartSec
        var result: [TranscriptSegment] = []

        for (i, item) in validSentences.enumerated() {
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let ratio = Double(max(1, trimmed.count)) / Double(totalChars)
            let dur = (i == validSentences.count - 1) ? max(0.05, windowEndSec - currentStart) : (windowDuration * ratio)
            let nextStart = min(windowEndSec, currentStart + dur)
            let spk = item.speaker.trimmingCharacters(in: .whitespacesAndNewlines)

            let seg = TranscriptSegment(
                id: "\(meetingId)_cloud_\(UUID().uuidString)_\(i)",
                startTime: currentStart,
                endTime: nextStart,
                text: trimmed,
                speakerLabel: spk.isEmpty ? fallbackSpeaker : spk,
                isFinal: true
            )
            result.append(seg)
            currentStart = nextStart
        }

        return result
    }

    // MARK: - 协议一：多模态 Chat Completions (input_audio)

    /// 带指数退避的通用 HTTP 执行方法（针对 HTTP 429 自动等待并重试最多 3 次）
    private func executeWithRetry(
        request: URLRequest,
        maxRetries: Int = 3,
        initialDelay: Double? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var currentDelay = initialDelay ?? retryDelay

        for attempt in 0...maxRetries {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw CloudTranscriptionError.networkError(error.localizedDescription)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudTranscriptionError.networkError("未能获取有效的 HTTP 响应")
            }

            if (200...299).contains(httpResponse.statusCode) {
                return (data, httpResponse)
            }

            let errorMsg = String(data: data, encoding: .utf8) ?? "未知错误"

            // 如果是 429 且尚未达到最大重试次数，执行退避重试
            if httpResponse.statusCode == 429 && attempt < maxRetries {
                AppLog.warn("[CloudTranscription] HTTP 429 Rate Limit (attempt \(attempt + 1)/\(maxRetries)). Waiting \(String(format: "%.1f", currentDelay))s before retrying...")
                try? await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                currentDelay *= 2.0
                continue
            }

            throw CloudTranscriptionError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        throw CloudTranscriptionError.httpError(statusCode: 429, message: "请求频次超限，多次重试后仍然超限")
    }

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
        request.timeoutInterval = 60

        if model.provider.lowercased().contains("openrouter") || model.apiURL.contains("openrouter.ai") {
            request.setValue("https://github.com/EastlakeStudio/AuraNote", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("AuraNote", forHTTPHeaderField: "X-Title")
        }

        var systemPrompt = "你是一个高精度的语音识别引擎。请将用户输入的音频准确转写为文本，并补充合适的标点符号。请直接输出转写的文本内容，不要输出任何多余的解释、寒暄或代码块格式。"
        if !hotwords.isEmpty {
            systemPrompt += "\n可能出现的专业术语/专有名词：\(hotwords)"
        }

        let userPrompt = "请识别并转写这段音频的对话内容："

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

        let (data, _) = try await executeWithRetry(request: request)

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
        request.timeoutInterval = 60

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

        let (data, _) = try await executeWithRetry(request: request)

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
        request.timeoutInterval = 60

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

        let (data, _) = try await executeWithRetry(request: request)

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
