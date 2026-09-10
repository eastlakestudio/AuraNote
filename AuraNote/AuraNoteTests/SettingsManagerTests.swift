import XCTest
@testable import AuraNote

@MainActor
final class SettingsManagerTests: XCTestCase {
    
    private var testDefaults: UserDefaults!
    
    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "AuruNoteTests")
        testDefaults.removePersistentDomain(forName: "AuruNoteTests")
        SettingsManager.shared.defaults = testDefaults
    }
    
    override func tearDown() {
        SettingsManager.shared.defaults = .standard
        KeychainHelper.delete(forKey: "llm_token")
        super.tearDown()
    }
    
    func testSettingsLoadDefaultValues() {
        let manager = SettingsManager.shared
        manager.load()
        
        // 验证加载的默认属性是否符合预期
        XCTAssertEqual(manager.llmURL, "")
        XCTAssertEqual(manager.llmToken, "")
        XCTAssertEqual(manager.llmModel, "gpt-4o")
        XCTAssertEqual(manager.selectedVoice, "openai/whisper-large-v3")
    }
    
    func testSettingsSaveAndLoad() {
        let manager = SettingsManager.shared
        
        // 修改配置数据
        manager.llmURL = "https://api.deepseek.com/v1"
        manager.llmToken = "sk-test-token-123456"
        manager.llmModel = "deepseek-chat"
        manager.selectedVoice = "openai/whisper-large-v3"
        manager.langSetting = "en"
        manager.summaryPrompt = "这是一个测试自定义提示词_test_suite_val"
        manager.summaryPrompt = "这是一个测试自定义提示词_test_suite_val"
        
        // 保存配置
        manager.save()
        
        // 验证 UserDefaults 直接存储的值（llmToken 已迁移到 Keychain，不再存于 UserDefaults）
        let defaults = testDefaults!
        XCTAssertEqual(defaults.string(forKey: "llm_url"), "https://api.deepseek.com/v1")
        XCTAssertNil(defaults.string(forKey: "llm_token")) // token 不在 UserDefaults 中
        XCTAssertEqual(KeychainHelper.read(forKey: "llm_token"), "sk-test-token-123456") // token 在 Keychain 中
        XCTAssertEqual(defaults.string(forKey: "llm_model"), "deepseek-chat")
        XCTAssertEqual(defaults.string(forKey: "voice_model"), "openai/whisper-large-v3")
        XCTAssertEqual(defaults.string(forKey: "summary_prompt"), "这是一个测试自定义提示词_test_suite_val")
        XCTAssertEqual(defaults.string(forKey: "ui_language"), "en")
        
        // 重新 load 并验证 manager 内的数据是否正确同步更新
        manager.load()
        XCTAssertEqual(manager.llmURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(manager.llmToken, "sk-test-token-123456")
        XCTAssertEqual(manager.llmModel, "deepseek-chat")
        XCTAssertEqual(manager.selectedVoice, "openai/whisper-large-v3")
        XCTAssertEqual(manager.summaryPrompt, "这是一个测试自定义提示词_test_suite_val")
        XCTAssertEqual(manager.langSetting, "en")
        
        XCTAssertTrue(manager.isLLMConfigured)
    }

    // MARK: - 多引擎就绪与自适应切换测试

    func testEngineReadinessWithCloudModelAndKey() {
        let manager = SettingsManager.shared
        manager.transcriptionEngine = .cloudModel

        let cloudManager = CloudModelManager.shared
        cloudManager.load()
        let testModelId = "gemini-transcribe"
        cloudManager.saveApiKey("test_mock_gemini_key_123", for: testModelId)

        // 验证在有 Key 情况下，云端转写引擎就绪，且 isModelAvailable 返回 true
        XCTAssertTrue(TranscriptionEngineCoordinator.shared.isCloudTranscriptionReady)
        XCTAssertTrue(manager.isCurrentEngineReady)
        XCTAssertTrue(manager.isModelAvailable)

        // 清理测试 Key
        cloudManager.deleteApiKey(for: testModelId)
    }

    func testEngineReadinessWithoutKey() {
        let manager = SettingsManager.shared
        manager.transcriptionEngine = .cloudModel

        let cloudManager = CloudModelManager.shared
        cloudManager.load()
        // 清理所有音频模型的 Key
        for model in cloudManager.models where model.isAudioTranscribeCapable {
            cloudManager.deleteApiKey(for: model.id)
        }

        // 验证在没有任何 Key 情况下，云端转写未就绪，isModelAvailable 返回 false
        XCTAssertFalse(TranscriptionEngineCoordinator.shared.isCloudTranscriptionReady)
        XCTAssertFalse(manager.isCurrentEngineReady)
        XCTAssertFalse(manager.isModelAvailable)
    }

    func testAutoSwitchToCloudOnLocalModelDeletion() {
        let manager = SettingsManager.shared
        manager.removeAllLocalASRModels()

        // 验证清理本地模型后，引擎自动自适应切换到 cloudModel
        XCTAssertEqual(manager.transcriptionEngine, .cloudModel)
    }

    func testEngineDidChangeNotification() {
        let manager = SettingsManager.shared
        let expectation = expectation(description: "Wait for engineDidChangeNotification")

        let observer = NotificationCenter.default.addObserver(
            forName: SettingsManager.engineDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        manager.transcriptionEngine = .cloudModel
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }
}
