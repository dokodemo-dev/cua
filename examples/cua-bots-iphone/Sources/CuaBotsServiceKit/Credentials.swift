// SPDX-License-Identifier: FSL-1.1-MIT

import Foundation
#if canImport(Security)
import Security
#endif

/// Stores the endpoint and its credential in the Keychain. The address is not
/// secret, but keeping both together means one item to clear on sign-out.
public enum CredentialStore {
    private static let service = "dev.dokodemo.cuabots"
    private static let account = "endpoint"

    public static func load() -> ServiceEndpoint? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let endpoint = try? JSONDecoder().decode(ServiceEndpoint.self, from: data)
        else { return nil }
        return endpoint
        #else
        return nil
        #endif
    }

    public static func save(_ endpoint: ServiceEndpoint) {
        guard let data = try? JSONEncoder().encode(endpoint) else { return }
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var insert = query
            insert.merge(attributes) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
        #endif
    }

    public static func clear() {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}
