import XCTest
@testable import AuraNote

final class KeychainHelperTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeychainHelper.clearInMemoryCacheForTesting()
    }

    override func tearDown() {
        KeychainHelper.deleteAPIKey(forModelId: "test-model-gemini")
        KeychainHelper.deleteAPIKey(forModelId: "test-model-openrouter")
        KeychainHelper.clearInMemoryCacheForTesting()
        super.tearDown()
    }

    func testSaveAndReadAPIKey() {
        let modelId = "test-model-gemini"
        let sampleKey = "AIzaSyTestApiKey1234567890"

        let saveSuccess = KeychainHelper.saveAPIKey(sampleKey, forModelId: modelId)
        XCTAssertTrue(saveSuccess)

        let retrieved = KeychainHelper.readAPIKey(forModelId: modelId)
        XCTAssertEqual(retrieved, sampleKey)
    }

    /// 核心测试：验证完全清除内存缓存（模拟进程重启）后，API Key 依然能从持久化存储中成功还原
    func testRestartPersistenceWithoutMemoryCache() {
        let modelId = "test-model-gemini"
        let sampleKey = "sk-restart-persistence-verification-token"

        KeychainHelper.saveAPIKey(sampleKey, forModelId: modelId)

        // 模拟进程完全退出，清空所有内存缓存
        KeychainHelper.clearInMemoryCacheForTesting()

        // 再次读取，验证沙盒/系统持久化层是否正常保留了该 Key
        let restoredKey = KeychainHelper.readAPIKey(forModelId: modelId)
        XCTAssertEqual(restoredKey, sampleKey, "进程重启后（内存缓存清空），API Key 必须能够完整从持久化层恢复！")
    }

    func testUpdateAPIKey() {
        let modelId = "test-model-gemini"
        let oldKey = "old-key-value-111"
        let newKey = "new-key-value-222"

        KeychainHelper.saveAPIKey(oldKey, forModelId: modelId)
        KeychainHelper.clearInMemoryCacheForTesting()
        XCTAssertEqual(KeychainHelper.readAPIKey(forModelId: modelId), oldKey)

        // 更新为新 Key
        KeychainHelper.saveAPIKey(newKey, forModelId: modelId)
        KeychainHelper.clearInMemoryCacheForTesting()
        XCTAssertEqual(KeychainHelper.readAPIKey(forModelId: modelId), newKey, "更新 Key 必须能正确覆盖旧值")
    }

    func testDeleteAPIKey() {
        let modelId = "test-model-gemini"
        let sampleKey = "key-to-be-deleted"

        KeychainHelper.saveAPIKey(sampleKey, forModelId: modelId)
        XCTAssertEqual(KeychainHelper.readAPIKey(forModelId: modelId), sampleKey)

        KeychainHelper.deleteAPIKey(forModelId: modelId)
        KeychainHelper.clearInMemoryCacheForTesting()

        let result = KeychainHelper.readAPIKey(forModelId: modelId)
        XCTAssertNil(result, "删除后的 API Key 不应被再次读取到")
    }

    func testModelSpecificKeyIsolation() {
        let modelA = "test-model-gemini"
        let modelB = "test-model-openrouter"
        let keyA = "key-for-gemini-aaa"
        let keyB = "key-for-openrouter-bbb"

        KeychainHelper.saveAPIKey(keyA, forModelId: modelA)
        KeychainHelper.saveAPIKey(keyB, forModelId: modelB)

        KeychainHelper.clearInMemoryCacheForTesting()

        XCTAssertEqual(KeychainHelper.readAPIKey(forModelId: modelA), keyA)
        XCTAssertEqual(KeychainHelper.readAPIKey(forModelId: modelB), keyB)
    }

    func testMaskedKey() {
        XCTAssertEqual(KeychainHelper.maskedKey(""), "")
        XCTAssertEqual(KeychainHelper.maskedKey("12345"), "******")
        let masked = KeychainHelper.maskedKey("AIzaSyTestApiKey1234567890")
        XCTAssertTrue(masked.contains("***"))
        XCTAssertTrue(masked.hasPrefix("AIz"))
        XCTAssertTrue(masked.hasSuffix("890"))
    }
}
