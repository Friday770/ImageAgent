import Foundation
import Security

/// Only the explicit GUI bootstrap consumes these variables. It never serializes credentials.
public struct EnvironmentConnection: Sendable {
    public let baseURL: String
    public let apiKey: String
    public static func consumeIfRequested(arguments: [String], read: (String) -> String?, clear: (String) -> Void) throws -> EnvironmentConnection? {
        guard arguments.contains("--configure-from-environment") else { return nil }
        let address = read("OPENAI_BASE_URL")
        let key = read("OPENAI_API_KEY")
        clear("OPENAI_BASE_URL"); clear("OPENAI_API_KEY")
        guard let address, !address.isEmpty, let key, !key.isEmpty else {
            throw ImageAgentError.credential("环境配置需要 OPENAI_BASE_URL 与 OPENAI_API_KEY；已清除本进程中的这两个变量。")
        }
        return .init(baseURL: address, apiKey: key)
    }
}

public protocol CredentialStore: Sendable {
    func key(for endpoint: String) throws -> String?
    func save(_ key: String, for endpoint: String) throws
    func delete(for endpoint: String) throws
}

public struct KeychainCredentialStore: CredentialStore {
    public static let service = "cn.mausy.ImageAgent"
    public init() {}
    private func query(_ endpoint: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: endpoint]
    }
    private func failure(_ status: OSStatus) -> ImageAgentError {
        .credential("无法访问此服务的钥匙串凭据（\(status)）。请重新输入 API Key 连接；本地历史仍会保留。")
    }
    public func key(for endpoint: String) throws -> String? {
        var q = query(endpoint); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw failure(status) }
        return key
    }
    public func save(_ key: String, for endpoint: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImageAgentError.credential("API Key 不能为空。") }
        let q = query(endpoint)
        let attrs: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; attrs.forEach { add[$0.key] = $0.value }; status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    public func delete(for endpoint: String) throws {
        let status = SecItemDelete(query(endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
}
