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
}
