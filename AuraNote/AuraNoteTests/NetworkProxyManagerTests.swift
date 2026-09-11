import XCTest
import CFNetwork
@testable import AuraNote

final class NetworkProxyManagerTests: XCTestCase {

    func testParseProxyURL_ImplicitScheme() {
        let manager = NetworkProxyManager.shared
        let config = manager.parseProxyURL("127.0.0.1:7890")
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.scheme, .http)
        XCTAssertEqual(config?.host, "127.0.0.1")
        XCTAssertEqual(config?.port, 7890)
        XCTAssertNil(config?.username)
        XCTAssertNil(config?.password)
    }

    func testParseProxyURL_ExplicitHTTP() {
        let manager = NetworkProxyManager.shared
        let config = manager.parseProxyURL("http://192.168.1.100:8080")
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.scheme, .http)
        XCTAssertEqual(config?.host, "192.168.1.100")
        XCTAssertEqual(config?.port, 8080)
    }

    func testParseProxyURL_ExplicitHTTPS() {
        let manager = NetworkProxyManager.shared
        let config = manager.parseProxyURL("https://proxy.example.com:8443")
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.scheme, .https)
        XCTAssertEqual(config?.host, "proxy.example.com")
        XCTAssertEqual(config?.port, 8443)
    }

    func testParseProxyURL_SOCKS5() {
        let manager = NetworkProxyManager.shared
        let config = manager.parseProxyURL("socks5://127.0.0.1:1080")
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.scheme, .socks5)
        XCTAssertEqual(config?.host, "127.0.0.1")
        XCTAssertEqual(config?.port, 1080)
    }

    func testParseProxyURL_WithAuth() {
        let manager = NetworkProxyManager.shared
        let config = manager.parseProxyURL("http://alice:secret123@127.0.0.1:7890")
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.scheme, .http)
        XCTAssertEqual(config?.host, "127.0.0.1")
        XCTAssertEqual(config?.port, 7890)
        XCTAssertEqual(config?.username, "alice")
        XCTAssertEqual(config?.password, "secret123")
    }

    func testParseProxyURL_InvalidInputs() {
        let manager = NetworkProxyManager.shared
        XCTAssertNil(manager.parseProxyURL(""))
        XCTAssertNil(manager.parseProxyURL("   \n\t"))
        XCTAssertNil(manager.parseProxyURL("127.0.0.1:70000")) // 端口超出 65535
        XCTAssertNil(manager.parseProxyURL("127.0.0.1:0")) // 端口不可为 0
    }

    func testBuildProxyDictionary_HTTP() {
        let manager = NetworkProxyManager.shared
        guard let config = manager.parseProxyURL("http://127.0.0.1:7890") else {
            XCTFail("解析失败")
            return
        }

        let dict = manager.buildProxyDictionary(from: config)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPEnable] as? Int, 1)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPProxy] as? String, "127.0.0.1")
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPPort] as? Int, 7890)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSEnable] as? Int, 1)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSProxy] as? String, "127.0.0.1")
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSPort] as? Int, 7890)
    }

    func testBuildProxyDictionary_SOCKS5() {
        let manager = NetworkProxyManager.shared
        guard let config = manager.parseProxyURL("socks5://user:pass@127.0.0.1:1080") else {
            XCTFail("解析失败")
            return
        }

        let dict = manager.buildProxyDictionary(from: config)
        XCTAssertEqual(dict[kCFStreamPropertySOCKSProxyHost] as? String, "127.0.0.1")
        XCTAssertEqual(dict[kCFStreamPropertySOCKSProxyPort] as? Int, 1080)
        XCTAssertEqual(dict[kCFStreamPropertySOCKSVersion] as? String, kCFStreamSocketSOCKSVersion5 as String)
        XCTAssertEqual(dict[kCFStreamPropertySOCKSUser] as? String, "user")
        XCTAssertEqual(dict[kCFStreamPropertySOCKSPassword] as? String, "pass")
    }

    func testApplyProxy_EnabledAndDisabled() {
        let manager = NetworkProxyManager.shared
        let sessionConfig = URLSessionConfiguration.default

        // 启用代理
        manager.applyProxy(to: sessionConfig, proxyString: "http://127.0.0.1:7890", isEnabled: true)
        XCTAssertNotNil(sessionConfig.connectionProxyDictionary)
        XCTAssertEqual(sessionConfig.connectionProxyDictionary?[kCFNetworkProxiesHTTPProxy] as? String, "127.0.0.1")

        // 禁用代理
        manager.applyProxy(to: sessionConfig, proxyString: "http://127.0.0.1:7890", isEnabled: false)
        XCTAssertNil(sessionConfig.connectionProxyDictionary)

        // 传入空地址
        manager.applyProxy(to: sessionConfig, proxyString: "", isEnabled: true)
        XCTAssertNil(sessionConfig.connectionProxyDictionary)
    }

    @MainActor
    func testSettingsManagerProxyPersistence() {
        let testDefaults = UserDefaults(suiteName: "NetworkProxyTests")!
        testDefaults.removePersistentDomain(forName: "NetworkProxyTests")
        let settings = SettingsManager.shared
        let originalDefaults = settings.defaults
        settings.defaults = testDefaults
        defer {
            settings.defaults = originalDefaults
        }

        XCTAssertFalse(settings.isCustomProxyEnabled)
        XCTAssertEqual(settings.customProxyURL, "http://127.0.0.1:7890")

        settings.isCustomProxyEnabled = true
        settings.customProxyURL = "http://127.0.0.1:6152"

        XCTAssertTrue(testDefaults.bool(forKey: "network_custom_proxy_enabled"))
        XCTAssertEqual(testDefaults.string(forKey: "network_custom_proxy_url"), "http://127.0.0.1:6152")
    }

    func testTestProxyConnectivity_InvalidAddress() async {
        let manager = NetworkProxyManager.shared
        let result = await manager.testProxyConnectivity(proxyString: "invalid:::url")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("格式无效"))
    }
}
