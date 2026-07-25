import XCTest
@testable import AuraNote

@MainActor
final class HotwordPresetsTests: XCTestCase {
    
    func testHotwordPresetsLoadAndGroup() {
        let manager = HotwordPresetsManager.shared
        manager.load()
        
        // 验证预设行业词库加载属性正常
        XCTAssertNotNil(manager.categories, "预设管理容器不可为空")
        
        // 如果是从Bundle中加载成功或者本地测试已构建好文件，验证检索过滤逻辑
        let categories = manager.categories
        if let first = categories.first {
            let wordsString = manager.getWords(for: [first.id])
            XCTAssertFalse(wordsString.isEmpty, "针对确切存在的ID查询对应热词组应当返回正确的非空拼合串")
        }
        
        // 验证未知或无效分类ID时不会出错并返回空
        let emptyWords = manager.getWords(for: ["invalid-test-category-id-999"])
        XCTAssertEqual(emptyWords, "", "查询不存在的分组应当平稳响应并输出空串")
    }
}
