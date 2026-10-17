import Foundation
#if canImport(Security)
import Security

actor BackupKeychain:BackupCredentialStore {
    private let service:String
    init(service:String) { self.service = service }
    private func query(_ destination:BackupDestination) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
         kSecAttrAccount as String:destination.server.absoluteString+"|"+destination.id+"|"+destination.deviceID,
         kSecAttrSynchronizable as String:false]
    }
    func token(for destination:BackupDestination) async throws -> String {
        var q = query(destination);q[kSecReturnData as String] = true;q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result:CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&result)
        guard status == errSecSuccess,let bytes = result as? Data,let token = String(data:bytes,encoding:.utf8) else { throw BackupProblem.authorization }
        return token
    }
    func save(_ token:String,for destination:BackupDestination) async throws {
        var q = query(destination)
        let value:[String:Any] = [kSecValueData as String:Data(token.utf8),
            kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(q as CFDictionary,value as CFDictionary)
        if update == errSecItemNotFound {
            for (key,v) in value { q[key] = v }
            guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw BackupProblem.authorization }
        } else if update != errSecSuccess { throw BackupProblem.authorization }
    }
    func remove(for destination:BackupDestination) async { SecItemDelete(query(destination) as CFDictionary) }
}
#endif
