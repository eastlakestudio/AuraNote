import XCTest
@testable import AuraNote

@MainActor
final class CloudModelTests: XCTestCase {

    private var testDefaults: UserDefaults!
    private let testModelIdA = "test-model-alpha"
    private let testModelIdB = "test-model-beta"

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "AuraNoteCloudTests")
        testDefaults.removePersistentDomain(forName: "AuraNoteCloudTests")
        CloudModelManager.shared.defaults = testDefaults
    }

    override func tearDown() {
        KeychainHelper.deleteAPIKey(forModelId: testModelIdA)
        KeychainHelper.deleteAPIKey(forModelId: testModelIdB)
        CloudModelManager.shared.defaults = .standard
        super.tearDown()
    }

    // MARK: - 1. JSON 解析与安全性断言

    func testCloudModelsJSONValidityAndSecurity() throws {
        let jsonURL: URL? = {
            if let bundleURL = Bundle.main.url(forResource: "cloud_models", withExtension: "json") {
                return bundleURL
            }
            // 测试工程直接文件路径查找
            let currentPath = URL(fileURLWithPath: #file)
            let projectRoot = currentPath.deletingLastPathComponent().deletingLastPathComponent()
            let resourceURL = projectRoot.appendingPathComponent("AuraNote/Resources/cloud_models.json")
            if FileManager.default.fileExists(atPath: resourceURL.path) {
                return resourceURL
            }
            return nil
        }()

        XCTAssertNotNil(jsonURL, "cloud_models.json 文件必须存在于项目或 Bundle 中")
        guard let url = jsonURL else { return }

        let data = try Data(contentsOf: url)
        let jsonString = String(data: data, encoding: .utf8) ?? ""

        // 安全断言：JSON 文件中绝不应包含明文 key 或 token 字段赋值
        XCTAssertFalse(jsonString.contains("sk-"), "JSON 预置文件绝不可包含真实的 API Key")
        XCTAssertFalse(jsonString.lowercased().contains("\"apikey\""), "JSON 预置文件绝不可定义 apiKey 字段")
        XCTAssertFalse(jsonString.lowercased().contains("\"api_key\""), "JSON 预置文件绝不可定义 api_key 字段")

        let decodedModels = try JSONDecoder().decode([CloudModel].self, from: data)
        XCTAssertFalse(decodedModels.isEmpty, "解密后的模型列表不可为空")

        for model in decodedModels {
            XCTAssertFalse(model.id.isEmpty, "模型 ID 不可为空")
            XCTAssertFalse(model.name.isEmpty, "模型显示名称不可为空")
            XCTAssertFalse(model.apiURL.isEmpty, "模型 API URL 不可为空")
            XCTAssertTrue(model.apiURL.hasPrefix("https://"), "API URL 必须以 https:// 开头以确保传输加密")
            XCTAssertFalse(model.modelName.isEmpty, "模型请求标识不可为空")
            XCTAssertFalse(model.provider.isEmpty, "模型供应商标签不可为空")
        }
    }

    // MARK: - 2. KeychainHelper 安全存储与模型隔离测试

    func testKeychainAPIKeyStorageAndIsolation() {
        let testKeyA = "sk-alpha-test-secret-123456"
        let testKeyB = "sk-beta-test-secret-789012"

        // 写入 A
        let saveResultA = KeychainHelper.saveAPIKey(testKeyA, forModelId: testModelIdA)
        XCTAssertTrue(saveResultA, "保存模型 A 的 API Key 应成功")

        // 写入 B
        let saveResultB = KeychainHelper.saveAPIKey(testKeyB, forModelId: testModelIdB)
        XCTAssertTrue(saveResultB, "保存模型 B 的 API Key 应成功")

        // 验证隔离读取
        let readKeyA = KeychainHelper.readAPIKey(forModelId: testModelIdA)
        let readKeyB = KeychainHelper.readAPIKey(forModelId: testModelIdB)
        XCTAssertEqual(readKeyA, testKeyA, "模型 A 读出的 Key 必须与写入一致")
        XCTAssertEqual(readKeyB, testKeyB, "模型 B 读出的 Key 必须与写入一致")
        XCTAssertNotEqual(readKeyA, readKeyB, "不同模型的 Key 必须彼此物理隔离")

        // 删除 A，验证不影响 B
        let deleteResultA = KeychainHelper.deleteAPIKey(forModelId: testModelIdA)
        XCTAssertTrue(deleteResultA, "删除模型 A 的 Key 应成功")
        XCTAssertNil(KeychainHelper.readAPIKey(forModelId: testModelIdA), "删除后模型 A 的 Key 应为空")
        XCTAssertEqual(KeychainHelper.readAPIKey(forModelId: testModelIdB), testKeyB, "删除模型 A 绝不可影响模型 B")
    }

    func testKeychainMaskedKeyUtility() {
        XCTAssertEqual(KeychainHelper.maskedKey(""), "")
        XCTAssertEqual(KeychainHelper.maskedKey("123"), "******")
        XCTAssertEqual(KeychainHelper.maskedKey("123456"), "******")
        
        let longKey = "sk-proj-abcdef1234567890"
        let masked = KeychainHelper.maskedKey(longKey)
        XCTAssertTrue(masked.contains("***"), "脱敏 Key 必须包含掩码星号")
        XCTAssertFalse(masked.contains("abcdef123456"), "脱敏 Key 绝不可包含完整中间敏感字符")
        XCTAssertTrue(masked.hasPrefix("sk-"), "脱敏 Key 应保留简短前缀以便辨识")
    }

    // MARK: - 3. CloudModelManager 状态与模型选择测试

    func testCloudModelManagerLifecycle() {
        let manager = CloudModelManager.shared
        manager.load()

        XCTAssertFalse(manager.models.isEmpty, "管理器中加载的模型不可为空")

        // 测试模型切换
        if let firstModel = manager.models.first {
            manager.selectedModelId = firstModel.id
            XCTAssertEqual(manager.selectedModel.id, firstModel.id)
        }

        // 测试 Key 存取联动
        let dummyKey = "sk-manager-test-key"
        manager.saveApiKey(dummyKey, for: testModelIdA)
        XCTAssertEqual(manager.apiKey(for: testModelIdA), dummyKey)

        manager.deleteApiKey(for: testModelIdA)
        XCTAssertEqual(manager.apiKey(for: testModelIdA), "")
    }

    // MARK: - 4. CloudLLMService 错误处理与参数校验

    func testCloudLLMServiceParameterValidation() async {
        let service = CloudLLMService.shared
        let dummyModel = CloudModel(
            id: "test",
            name: "Test",
            provider: "Test",
            apiURL: "https://invalid.example.com/v1/chat",
            modelName: "test-model"
        )

        // 1. 空 Key 校验
        do {
            _ = try await service.testConnection(model: dummyModel, apiKey: "")
            XCTFail("API Key 为空时必须抛出异常")
        } catch let err as CloudLLMError {
            switch err {
            case .emptyAPIKey:
                break // 预期行为
            default:
                XCTFail("预期抛出 emptyAPIKey，实际得到: \(err)")
            }
        } catch {
            XCTFail("未捕获到正确的 CloudLLMError: \(error)")
        }

        // 2. 空 URL 校验
        let emptyURLModel = CloudModel(
            id: "test2",
            name: "Test2",
            provider: "Test",
            apiURL: "",
            modelName: "test-model"
        )
        do {
            _ = try await service.testConnection(model: emptyURLModel, apiKey: "sk-somekey")
            XCTFail("API URL 非法时必须抛出异常")
        } catch let err as CloudLLMError {
            switch err {
            case .invalidURL:
                break // 预期行为
            default:
                XCTFail("预期抛出 invalidURL，实际得到: \(err)")
            }
        } catch {
            XCTFail("未捕获到正确的 CloudLLMError: \(error)")
        }
    }

    // MARK: - 5. DatabaseManager 纪要持久化测试

    func testDatabaseManagerUpdateMeetingSummary() throws {
        let db = DatabaseManager()
        let testMeeting = Meeting.create(title: "纪要持久化测试会议")
        try db.createMeeting(testMeeting)

        let summaryText = "### 1. 会议概况\n讨论了云端大模型集成与数据安全。\n### 2. 结论\n通过钥匙串存储 API Key。"
        try db.updateMeetingSummary(id: testMeeting.id, summary: summaryText, status: .completed)

        let allMeetings = db.fetchAllMeetings()
        let found = allMeetings.first(where: { $0.id == testMeeting.id })

        XCTAssertNotNil(found, "刚刚插入并更新的会议应可检索到")
        XCTAssertEqual(found?.summary, summaryText, "存储的会议纪要必须能无损读取")
        XCTAssertEqual(found?.status, .completed, "会议状态应更新为 completed")

        // 清理测试数据
        try db.deleteMeeting(id: testMeeting.id)
    }
}
