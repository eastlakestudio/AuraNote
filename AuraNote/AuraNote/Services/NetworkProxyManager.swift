import Foundation
import CFNetwork

/// 代理协议类型
public enum ProxyScheme: String, Sendable, CaseIterable {
    case http = "http"
    case https = "https"
    case socks5 = "socks5"
}

/// 解析后的代理配置实体
public struct ParsedProxyConfig: Equatable, Sendable {
    public let scheme: ProxyScheme
    public let host: String
    public let port: Int
    public let username: String?
    public let password: String?

    public init(scheme: ProxyScheme, host: String, port: Int, username: String? = nil, password: String? = nil) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

/// 全局网络代理管理单例
/// 负责统一管理 App 内所有基于 URLSession 的网络请求代理注入与连通性自检
public final class NetworkProxyManager: @unchecked Sendable {
    public static let shared = NetworkProxyManager()

    private init() {}

    // MARK: - 代理字符串解析

    /// 解析用户输入的代理 URL 字符串
    /// 支持常见输入格式：
    /// - `127.0.0.1:7890` (自动推断为 http)
    /// - `http://127.0.0.1:7890`
    /// - `https://127.0.0.1:7890`
    /// - `socks5://127.0.0.1:7890`
    /// - `socks://127.0.0.1:1080`
    /// - `http://user:password@127.0.0.1:7890`
    public func parseProxyURL(_ rawString: String) -> ParsedProxyConfig? {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let urlString = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            return nil
        }

        let rawScheme = (url.scheme ?? "http").lowercased()
        let scheme: ProxyScheme
        if rawScheme == "socks5" || rawScheme == "socks" {
            scheme = .socks5
        } else if rawScheme == "https" {
            scheme = .https
        } else {
            scheme = .http
        }

        let defaultPort: Int = (scheme == .socks5) ? 1080 : 7890
        let port = url.port ?? defaultPort
        guard port > 0 && port <= 65535 else { return nil }

        return ParsedProxyConfig(
            scheme: scheme,
            host: host,
            port: port,
            username: url.user,
            password: url.password
        )
    }

    // MARK: - CFNetwork 代理字典映射

    /// 将代理配置转换为 URLSessionConfiguration.connectionProxyDictionary 所需的字典
    public func buildProxyDictionary(from config: ParsedProxyConfig) -> [AnyHashable: Any] {
        var dict: [AnyHashable: Any] = [:]

        switch config.scheme {
        case .socks5:
            dict[kCFStreamPropertySOCKSProxyHost] = config.host
            dict[kCFStreamPropertySOCKSProxyPort] = config.port
            dict[kCFStreamPropertySOCKSVersion] = kCFStreamSocketSOCKSVersion5
            if let user = config.username {
                dict[kCFStreamPropertySOCKSUser] = user
            }
            if let pass = config.password {
                dict[kCFStreamPropertySOCKSPassword] = pass
            }

        case .http, .https:
            dict[kCFNetworkProxiesHTTPEnable] = 1
            dict[kCFNetworkProxiesHTTPProxy] = config.host
            dict[kCFNetworkProxiesHTTPPort] = config.port
            dict[kCFNetworkProxiesHTTPSEnable] = 1
            dict[kCFNetworkProxiesHTTPSProxy] = config.host
            dict[kCFNetworkProxiesHTTPSPort] = config.port
        }

        return dict
    }

    /// 从代理字符串构建代理字典（如果未开启或解析失败则返回 nil）
    public func buildProxyDictionary(from proxyString: String?, isEnabled: Bool) -> [AnyHashable: Any]? {
        guard isEnabled, let raw = proxyString, !raw.isEmpty else { return nil }
        guard let config = parseProxyURL(raw) else { return nil }
        return buildProxyDictionary(from: config)
    }

    // MARK: - 会话配置注入

    /// 向指定的 URLSessionConfiguration 注入或清除自定义代理
    public func applyProxy(to config: URLSessionConfiguration, proxyString: String?, isEnabled: Bool) {
        if let proxyDict = buildProxyDictionary(from: proxyString, isEnabled: isEnabled) {
            config.connectionProxyDictionary = proxyDict
        } else {
            config.connectionProxyDictionary = nil
        }
    }

    // MARK: - 代理连通性测试

    /// 测试指定代理地址与目标服务器的连通性
    /// - Parameters:
    ///   - proxyString: 代理地址字符串
    ///   - targetURL: 探测目标 URL（默认 Google Gemini API 域名）
    /// - Returns: 测试结果（是否成功、诊断提示信息、耗时毫秒数）
    public func testProxyConnectivity(
        proxyString: String,
        targetURL: URL = URL(string: "https://generativelanguage.googleapis.com")!
    ) async -> (success: Bool, message: String, latencyMs: Double) {
        guard let config = parseProxyURL(proxyString) else {
            return (false, "代理地址格式无效，请检查主机名和端口", 0)
        }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 8
        sessionConfig.timeoutIntervalForResource = 10
        sessionConfig.connectionProxyDictionary = buildProxyDictionary(from: config)

        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: targetURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let (_, response) = try await session.data(for: request)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

            if let httpResponse = response as? HTTPURLResponse {
                // 即使返回 400/403/404，也表明成功穿越代理到达目标 API 服务端
                return (true, "代理连通成功 (HTTP \(httpResponse.statusCode)，时延 \(Int(elapsedMs))ms)", elapsedMs)
            }
            return (true, "代理连通成功 (时延 \(Int(elapsedMs))ms)", elapsedMs)
        } catch let urlError as URLError {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            switch urlError.code {
            case .cannotConnectToHost:
                return (false, "无法连接到代理端口 (Connection Refused)，请确认代理软件已启动且端口为 \(config.port)", elapsedMs)
            case .timedOut:
                return (false, "代理连接超时，请检查代理节点是否通畅或网络是否被阻断", elapsedMs)
            case .dnsLookupFailed:
                return (false, "代理主机名解析失败 (\(config.host))", elapsedMs)
            case .networkConnectionLost:
                return (false, "网络连接在通过代理传输时中断", elapsedMs)
            default:
                return (false, "代理连接失败: \(urlError.localizedDescription)", elapsedMs)
            }
        } catch {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return (false, "代理连接失败: \(error.localizedDescription)", elapsedMs)
        }
    }
}
