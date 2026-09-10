import XCTest
@testable import AuraNote

final class CloudTranscriptionTests: XCTestCase {

    // MARK: - WAV 编码器测试

    func testWAVDataEncoderHeader() {
        let samples: [Float] = [0.0, 0.5, -0.5, 0.2, -0.2]
        let sampleRate = 16000
        let data = WAVDataEncoder.encodeToWAVData(samples: samples, sampleRate: sampleRate)

        // 验证最小字节数: 44 字节头 + 5 采样 * 2 字节 = 54 字节
        XCTAssertEqual(data.count, 44 + samples.count * 2)

        // 验证 RIFF 标头
        let riff = String(data: data.subdata(in: 0..<4), encoding: .ascii)
        XCTAssertEqual(riff, "RIFF")

        // 验证 WAVE
        let wave = String(data: data.subdata(in: 8..<12), encoding: .ascii)
        XCTAssertEqual(wave, "WAVE")

        // 验证 fmt
        let fmt = String(data: data.subdata(in: 12..<16), encoding: .ascii)
        XCTAssertEqual(fmt, "fmt ")

        // 验证 data
        let subdataTag = String(data: data.subdata(in: 36..<40), encoding: .ascii)
        XCTAssertEqual(subdataTag, "data")
    }

    func testWAVBase64Encoding() {
        let samples: [Float] = [Float](repeating: 0.1, count: 160)
        let base64 = WAVDataEncoder.encodeToBase64WAV(samples: samples, sampleRate: 16000)

        XCTAssertFalse(base64.isEmpty)
        guard let decoded = Data(base64Encoded: base64) else {
            XCTFail("Base64 解码失败")
            return
        }
        XCTAssertEqual(decoded.count, 44 + samples.count * 2)
    }

    func testSilentTestAudioGeneration() {
        let duration: Double = 1.0
        let sampleRate = 16000
        let silentData = WAVDataEncoder.createTestSilentWAVData(durationSeconds: duration, sampleRate: sampleRate)
        let expectedBytes = 44 + Int(duration * Double(sampleRate)) * 2
        XCTAssertEqual(silentData.count, expectedBytes)

        let silentBase64 = WAVDataEncoder.createTestSilentBase64WAV(durationSeconds: duration, sampleRate: sampleRate)
        XCTAssertFalse(silentBase64.isEmpty)
    }

    // MARK: - 模型能力识别测试

    func testCloudModelAudioCapability() {
        let manager = CloudModelManager.shared
        manager.load()
        let models = manager.models

        // 验证 MAI-Transcribe-2 具备音频能力
        if let mai = models.first(where: { $0.id == "mai-transcribe-2" }) {
            XCTAssertTrue(mai.isAudioTranscribeCapable)
            XCTAssertEqual(mai.audioEndpointType, .chatAudio)
        } else {
            XCTFail("未找到 mai-transcribe-2 模型")
        }

        // 验证 Gemini 3.5 Transcribe 具备音频能力
        if let gemini = models.first(where: { $0.id == "gemini-transcribe" }) {
            XCTAssertTrue(gemini.isAudioTranscribeCapable)
            XCTAssertEqual(gemini.audioEndpointType, .chatAudio)
        } else {
            XCTFail("未找到 gemini-transcribe 模型")
        }

        // 验证 Qwen-Audio 具备音频能力
        if let qwen = models.first(where: { $0.id == "qwen-audio" }) {
            XCTAssertTrue(qwen.isAudioTranscribeCapable)
        } else {
            XCTFail("未找到 qwen-audio 模型")
        }

        // 验证 DeepSeek-V3 为纯文本模型，不具备语音转写能力
        if let deepseek = models.first(where: { $0.id == "deepseek-chat" }) {
            XCTAssertFalse(deepseek.isAudioTranscribeCapable)
        } else {
            XCTFail("未找到 deepseek-chat 模型")
        }
    }

    // MARK: - 云端服务与异常处理测试

    func testCloudTranscriptionMissingAPIKey() async {
        let service = CloudTranscriptionService()
        let model = CloudModel(
            id: "test-model",
            name: "Test Audio Model",
            provider: "Test",
            apiURL: "https://api.test.com/v1/chat/completions",
            modelName: "test-model",
            supportsAudio: true,
            audioEndpointType: .chatAudio
        )

        do {
            _ = try await service.transcribeSamples(
                samples: [0.1, 0.2, -0.1],
                sampleRate: 16000,
                hotwords: "",
                model: model,
                apiKey: ""
            )
            XCTFail("未配置 API-KEY 应该抛出 missingAPIKey 异常")
        } catch let error as CloudTranscriptionError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("抛出了非预期的错误: \(error)")
        }
    }

    // MARK: - Mock 网络转写响应测试

    func testMockCloudTranscriptionResponse() async throws {
        // 配置自定义 URLProtocol Mock
        MockTranscriptionURLProtocol.mockContent = "大家好，今天我们进行季度项目复盘评审。"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockTranscriptionURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        let service = CloudTranscriptionService(session: mockSession)
        let model = CloudModel(
            id: "gemini-transcribe",
            name: "Google Gemini 3.5 Transcribe",
            provider: "Google",
            apiURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            modelName: "gemini-2.5-flash",
            supportsAudio: true,
            audioEndpointType: .chatAudio
        )

        let samples = [Float](repeating: 0.05, count: 4800) // 0.3s
        let result = try await service.transcribeSamples(
            samples: samples,
            sampleRate: 16000,
            hotwords: "项目评审",
            model: model,
            apiKey: "mock-key-12345"
        )

        XCTAssertEqual(result, "大家好，今天我们进行季度项目复盘评审。")
    }

    // MARK: - Gemini 3.5 端到端多说话人 / 抢话转写测试

    func testGeminiMultiSpeakerCrosstalkDiarization() async throws {
        let jsonResponse = """
        [
          {"speaker": "李总", "text": "下季度的预算方案准备好了吗？"},
          {"speaker": "王经理", "text": "已经做好了，马上同步给各位。"}
        ]
        """
        MockTranscriptionURLProtocol.mockContent = jsonResponse
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockTranscriptionURLProtocol.self]
        let mockSession = URLSession(configuration: mockSessionConfig(MockTranscriptionURLProtocol.self))

        let service = CloudTranscriptionService(session: mockSession)
        let model = CloudModel(
            id: "gemini-transcribe",
            name: "Google Gemini 3.5 Transcribe",
            provider: "Google",
            apiURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            modelName: "gemini-2.5-flash",
            supportsAudio: true,
            audioEndpointType: .chatAudio
        )

        let samples = [Float](repeating: 0.05, count: 8000) // 0.5s
        let results = try await service.transcribeAndDiarizeSamples(
            samples: samples,
            sampleRate: 16000,
            contextSpeakers: ["李总", "王经理"],
            priorSpeaker: "李总",
            model: model,
            apiKey: "mock-gemini-key"
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].speaker, "李总")
        XCTAssertEqual(results[0].text, "下季度的预算方案准备好了吗？")
        XCTAssertEqual(results[1].speaker, "王经理")
        XCTAssertEqual(results[1].text, "已经做好了，马上同步给各位。")
    }

    func testGeminiSingleSpeakerResponse() async throws {
        let jsonResponse = """
        [
          {"speaker": "张三", "text": "收到，我正在处理。"}
        ]
        """
        MockTranscriptionURLProtocol.mockContent = jsonResponse
        let mockSession = URLSession(configuration: mockSessionConfig(MockTranscriptionURLProtocol.self))

        let service = CloudTranscriptionService(session: mockSession)
        let model = CloudModel(
            id: "gemini-transcribe",
            name: "Google Gemini 3.5 Transcribe",
            provider: "Google",
            apiURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            modelName: "gemini-2.5-flash",
            supportsAudio: true,
            audioEndpointType: .chatAudio
        )

        let samples = [Float](repeating: 0.05, count: 6400) // 0.4s
        let results = try await service.transcribeAndDiarizeSamples(
            samples: samples,
            sampleRate: 16000,
            contextSpeakers: ["张三"],
            model: model,
            apiKey: "mock-gemini-key"
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].speaker, "张三")
        XCTAssertEqual(results[0].text, "收到，我正在处理。")
    }

    func testGeminiMarkdownFencedJSONParsing() async throws {
        let rawContent = """
        ```json
        [
          {"speaker": "陈工", "text": "网络链路已全部打通。"}
        ]
        ```
        """
        MockTranscriptionURLProtocol.mockContent = rawContent
        let mockSession = URLSession(configuration: mockSessionConfig(MockTranscriptionURLProtocol.self))

        let service = CloudTranscriptionService(session: mockSession)
        let model = CloudModel(
            id: "gemini-transcribe",
            name: "Google Gemini 3.5 Transcribe",
            provider: "Google",
            apiURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            modelName: "gemini-2.5-flash",
            supportsAudio: true,
            audioEndpointType: .chatAudio
        )

        let samples = [Float](repeating: 0.05, count: 6400)
        let results = try await service.transcribeAndDiarizeSamples(
            samples: samples,
            sampleRate: 16000,
            model: model,
            apiKey: "mock-gemini-key"
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].speaker, "陈工")
        XCTAssertEqual(results[0].text, "网络链路已全部打通。")
    }

    func testGeminiColonTextFallbackParsing() async throws {
        let rawContent = """
        Speaker 1: 请确认这个计划。
        Speaker 2: 没问题，赞同。
        """
        MockTranscriptionURLProtocol.mockContent = rawContent
        let mockSession = URLSession(configuration: mockSessionConfig(MockTranscriptionURLProtocol.self))

        let service = CloudTranscriptionService(session: mockSession)
        let model = CloudModel(
            id: "gemini-transcribe",
            name: "Google Gemini 3.5 Transcribe",
            provider: "Google",
            apiURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            modelName: "gemini-2.5-flash",
            supportsAudio: true,
            audioEndpointType: .chatAudio
        )

        let samples = [Float](repeating: 0.05, count: 6400)
        let results = try await service.transcribeAndDiarizeSamples(
            samples: samples,
            sampleRate: 16000,
            model: model,
            apiKey: "mock-gemini-key"
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].speaker, "Speaker 1")
        XCTAssertEqual(results[0].text, "请确认这个计划。")
        XCTAssertEqual(results[1].speaker, "Speaker 2")
        XCTAssertEqual(results[1].text, "没问题，赞同。")
    }

    // MARK: - 本地模型清理测试

    func testSettingsManagerRemoveLocalModels() {
        let settings = SettingsManager.shared
        // 验证清理方法执行无异常且重置状态
        settings.removeAllLocalASRModels()
        XCTAssertFalse(settings.isFp32ModelAvailable)
        XCTAssertFalse(settings.localModelsDiskUsageString.isEmpty)
    }

    private func mockSessionConfig(_ protocolClass: AnyClass) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        return config
    }
}

// MARK: - Mock URLProtocol 用于网络转写测试

final class MockTranscriptionURLProtocol: URLProtocol {
    nonisolated(unsafe) static var mockContent: String = "大家好，今天我们进行季度项目复盘评审。"

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let responseJson: [String: Any] = [
            "id": "mock_chat_123",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": MockTranscriptionURLProtocol.mockContent
                    ]
                ]
            ]
        ]

        guard let responseData = try? JSONSerialization.data(withJSONObject: responseJson),
              let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://mock.transcribe.api")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
