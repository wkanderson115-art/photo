import Foundation
import Security

struct CloudConfiguration {
    static let deepSeekDefault = "deepseek-flash"
    static let seedreamDefault = "doubao-seedream-5-0-pro-260628"
    static var seedreamModel: String { UserDefaults.standard.string(forKey: "seedreamModel") ?? seedreamDefault }

}

enum APIKeyStore {
    enum Provider: String { case deepseek, seedream }
    private static var service: String { (Bundle.main.bundleIdentifier ?? "OutdoorPhotoAssistant") + ".cloudKeys" }
    static func read(_ provider: Provider) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, for provider: Provider) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw keyError(status) }
            return
        }
        guard !key.contains(where: { $0.isWhitespace }), key.count < 2048 else {
            throw NSError(domain: "APIKeyStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Key格式不正确，请检查空格或换行。"])
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keyError(status) }
    }
    /// The backend session belongs to an older version and is no longer used.
    static func removeLegacyBackendSession() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service, kSecAttrAccount as String: "backend"] as CFDictionary)
    }
    private static func keyError(_ status: OSStatus) -> NSError {
        NSError(domain: "APIKeyStore", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "无法保存Key到系统钥匙串，请解锁设备后重试。"])
    }
}
