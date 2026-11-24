import Foundation
import Security

struct KeychainEntry: Codable, Equatable {
    let service: String
    let account: String

    static func porubot(_ account: String) -> Self {
        Self(service: "local.antigravity.tasks.api-key", account: account)
    }

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func save(_ value: String) -> Swift.Result<Void, KeychainFailure> {
        let payload = [kSecValueData as String: Data(value.utf8)]
        var item = identity
        item.merge(payload) { _, value in value }
        let status = SecItemAdd(item as CFDictionary, nil)
        let finalStatus = status == errSecDuplicateItem
            ? SecItemUpdate(identity as CFDictionary, payload as CFDictionary) : status
        return finalStatus == errSecSuccess ? .success(()) : .failure(.status(finalStatus))
    }

    func read() -> Swift.Result<String, KeychainFailure> {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return .failure(.status(status)) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.empty)
        }
        return .success(value)
    }
}

enum KeychainFailure: Error {
    case status(OSStatus)
    case empty

    var isMissing: Bool {
        if case .status(errSecItemNotFound) = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .status(errSecItemNotFound): return "Запись не найдена. Проверь имя службы и учётную запись."
        case .status(errSecUserCanceled), .status(errSecAuthFailed), .status(errSecInteractionNotAllowed):
            return "macOS не разрешила прочитать запись."
        case let .status(status): return "Не удалось прочитать запись (код \(status))."
        case .empty: return "В записи нет текстового API-ключа."
        }
    }
}
