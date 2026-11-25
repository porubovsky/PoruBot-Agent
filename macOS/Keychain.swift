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
        case .status(errSecItemNotFound): return tr("Запись не найдена. Проверь имя службы и учётную запись.", "Entry not found. Check the service name and account.")
        case .status(errSecUserCanceled):
            return tr("Доступ отменён. Нажми «Загрузить ключ» и подтверди запрос macOS.", "Access canceled. Select Load key and confirm the macOS prompt.")
        case .status(errSecAuthFailed), .status(errSecInteractionNotAllowed):
            return tr("macOS не дала доступ. Разблокируй связку «Вход» и повтори загрузку.", "macOS denied access. Unlock the login keychain and try again.")
        case let .status(status): return tr("Не удалось прочитать запись (код \(status)).", "Could not read the entry (code \(status)).")
        case .empty: return tr("В записи нет текстового API-ключа.", "This entry does not contain a text API key.")
        }
    }
}
