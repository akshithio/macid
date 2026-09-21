import CryptoKit
import Foundation
import OpenDirectory
import Security

/// The Mac password, sealed to the Secure Enclave, used to unlock the login keychain after a face unlock.
public enum StoredPassword {

    public enum Problem: LocalizedError {
        case wrongPassword
        case noSecureEnclave
        case couldNotSave(String)

        public var errorDescription: String? {
            switch self {
            case .wrongPassword: return "That isn't the password for this Mac."
            case .noSecureEnclave: return "This Mac has no Secure Enclave to protect the password with."
            case .couldNotSave(let why): return "MacID couldn't save the password: \(why)"
            }
        }
    }

    private struct Sealed: Codable {
        /// The Secure Enclave key's opaque handle.
        var key: Data
        var ephemeral: Data
        var box: Data
    }

    static var url: URL { Paths.dir.appendingPathComponent("password.sealed") }

    public static var isStored: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Checks the password against your account, then seals and saves it.
    public static func save(_ password: String) throws {
        guard isCorrect(password) else { throw Problem.wrongPassword }
        guard SecureEnclave.isAvailable else { throw Problem.noSecureEnclave }
        do {
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let symmetric = try derive(ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey))
            let box = try AES.GCM.seal(Data(password.utf8), using: symmetric).combined!
            let sealed = Sealed(key: key.dataRepresentation,
                                ephemeral: ephemeral.publicKey.rawRepresentation,
                                box: box)
            let data = try JSONEncoder().encode(sealed)
            FileManager.default.createFile(atPath: url.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
            guard isStored else { throw Problem.couldNotSave("the file could not be written") }
        } catch let problem as Problem {
            throw problem
        } catch {
            throw Problem.couldNotSave(error.localizedDescription)
        }
    }

    public static func load() -> String? {
        guard let data = try? Data(contentsOf: url),
              let sealed = try? JSONDecoder().decode(Sealed.self, from: data),
              let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: sealed.key),
              let ephemeral = try? P256.KeyAgreement.PublicKey(rawRepresentation: sealed.ephemeral),
              let symmetric = try? derive(key.sharedSecretFromKeyAgreement(with: ephemeral)),
              let box = try? AES.GCM.SealedBox(combined: sealed.box),
              let plain = try? AES.GCM.open(box, using: symmetric)
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether `password` is the account password, checked with Open Directory.
    public static func isCorrect(_ password: String) -> Bool {
        guard let node = try? ODNode(session: ODSession.default(),
                                     type: ODNodeType(kODNodeTypeAuthentication)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers,
                                            name: NSUserName(), attributes: nil)
        else { return false }
        return (try? record.verifyPassword(password)) != nil
    }

    @discardableResult
    public static func unlockKeychain(with password: String) -> Bool {
        if LoginKeychain.isUnlocked { return true }
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return false }
        let bytes = Array(password.utf8)
        return SecKeychainUnlock(keychain, UInt32(bytes.count), bytes, true) == errSecSuccess
    }

    private static func derive(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                       salt: Data("MacID password".utf8),
                                       sharedInfo: Data(),
                                       outputByteCount: 32)
    }
}
