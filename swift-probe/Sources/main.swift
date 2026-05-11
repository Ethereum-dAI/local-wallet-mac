import Foundation
import CryptoKit
import LocalAuthentication

// =============================================================================
// Secure Enclave P-256 Probe
//
// Modes:
//   swift run swift-probe                          — generate key, sign default hash
//   swift run swift-probe -- --sign-preimage <hex> — sign a specific 69-byte preimage
//   swift run swift-probe -- --biometric           — require Touch ID
//   swift run swift-probe -- --new-key             — force generate a new key
//
// The key is persisted in Keychain with tag "com.localwallet.probe".
// Subsequent runs reuse the same key unless --new-key is passed.
// =============================================================================

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

let rpId = "wallet"
let origin = "https://wallet.local"
let keyTag = "com.localwallet.probe"

let defaultUserOpHash = Data(hexString: "6d0a394861c05e39fb043ecfa6bca7ef8976ee6c8300547977c39b8a39b39dda")!

// ---------------------------------------------------------------------------
// Base64url encoding (RFC 4648 §5, no padding)
// ---------------------------------------------------------------------------

func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// ---------------------------------------------------------------------------
// WebAuthn ceremony construction
// ---------------------------------------------------------------------------

func buildAuthenticatorData() -> Data {
    let rpIdHash = SHA256.hash(data: Data(rpId.utf8))
    var data = Data(rpIdHash)
    data.append(0x05)
    data.append(contentsOf: [UInt8](repeating: 0, count: 4))
    return data
}

func buildClientDataJSON(userOpHash: Data) -> String {
    let challenge = base64urlEncode(userOpHash)
    return """
    {"type":"webauthn.get","challenge":"\(challenge)","origin":"\(origin)","crossOrigin":false}
    """.trimmingCharacters(in: .whitespacesAndNewlines)
}

func computeSigningPreimage(userOpHash: Data) -> (preimage: Data, signingMessage: Data, clientDataJSON: String) {
    let authData = buildAuthenticatorData()
    let clientDataJSON = buildClientDataJSON(userOpHash: userOpHash)
    let clientDataHash = SHA256.hash(data: Data(clientDataJSON.utf8))
    let preimage = authData + Data(clientDataHash)
    let signingMessage = SHA256.hash(data: preimage)
    return (preimage, Data(signingMessage), clientDataJSON)
}

// ---------------------------------------------------------------------------
// Keychain key persistence
// ---------------------------------------------------------------------------

func loadKey() -> SecureEnclave.P256.Signing.PrivateKey? {
    do {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
    } catch {
        print("Warning: could not load key: \(error)")
        return nil
    }
}

func saveKey(_ key: SecureEnclave.P256.Signing.PrivateKey) {
    // Delete any existing key first
    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keyTag,
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keyTag,
        kSecValueData as String: key.dataRepresentation,
    ]
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecSuccess {
        print("Key saved to Keychain (tag: \(keyTag))")
    } else {
        print("Warning: could not save key to Keychain: \(status)")
    }
}

// ---------------------------------------------------------------------------
// Hex utilities
// ---------------------------------------------------------------------------

extension Data {
    init?(hexString: String) {
        let hex = hexString.dropFirst(hexString.hasPrefix("0x") ? 2 : 0)
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

let args = CommandLine.arguments
let useBiometric = args.contains("--biometric")
let forceNewKey = args.contains("--new-key")

// Check for --sign-preimage <hex>
var customPreimage: Data? = nil
if let idx = args.firstIndex(of: "--sign-preimage"), idx + 1 < args.count {
    guard let data = Data(hexString: args[idx + 1]), data.count == 69 else {
        print("ERROR: --sign-preimage requires exactly 69 bytes (138 hex chars)")
        exit(1)
    }
    customPreimage = data
}

print("=== Secure Enclave P-256 Probe ===\n")

// 1. Load or generate key
do {
    let privateKey: SecureEnclave.P256.Signing.PrivateKey

    if !forceNewKey, let existingKey = loadKey() {
        print("Loaded existing key from Keychain")
        privateKey = existingKey
    } else {
        if useBiometric {
            print("Generating NEW Secure Enclave key (Touch ID required)...")
            let context = LAContext()
            context.localizedReason = "Generate signing key"
            let semaphore = DispatchSemaphore(value: 0)
            var authError: Error?
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Generate signing key") { success, error in
                if !success { authError = error }
                semaphore.signal()
            }
            semaphore.wait()
            if let authError { throw authError }

            var cfError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &cfError
            ) else {
                throw cfError!.takeRetainedValue() as Error
            }
            privateKey = try SecureEnclave.P256.Signing.PrivateKey(
                accessControl: accessControl, authenticationContext: context
            )
        } else {
            print("Generating NEW Secure Enclave key...")
            privateKey = try SecureEnclave.P256.Signing.PrivateKey()
        }
        saveKey(privateKey)
    }

    // Print public key
    let publicKey = privateKey.publicKey
    let rawPubKey = publicKey.x963Representation
    let pubKeyX = rawPubKey[1..<33]
    let pubKeyY = rawPubKey[33..<65]

    print("pubkey_x:          \(Data(pubKeyX).hexString)")
    print("pubkey_y:          \(Data(pubKeyY).hexString)")
    print()

    // 2. Determine what to sign
    let preimage: Data
    if let custom = customPreimage {
        print("Signing custom preimage (\(custom.count) bytes)")
        preimage = custom
    } else {
        let (p, sm, cdj) = computeSigningPreimage(userOpHash: defaultUserOpHash)
        preimage = p
        print("userOpHash:        \(defaultUserOpHash.hexString)")
        print("clientDataJSON:    \(cdj)")
        print("signingMessage:    \(sm.hexString)")
    }
    print("preimage:          \(preimage.hexString)")
    print()

    // 3. Sign
    let signature = try privateKey.signature(for: preimage)
    let rawSig = signature.rawRepresentation
    let r = rawSig[0..<32]
    let s = rawSig[32..<64]

    print("r:                 \(Data(r).hexString)")
    print("s:                 \(Data(s).hexString)")
    print("der_signature:     \(Data(signature.derRepresentation).hexString)")
    print()

    // 4. Verify locally
    let isValid = publicKey.isValidSignature(signature, for: preimage)
    print("local_verify:      \(isValid)")
    print()

    // 5. Output
    print("=== Copy these values ===\n")
    print("pubkey_x: \(Data(pubKeyX).hexString)")
    print("pubkey_y: \(Data(pubKeyY).hexString)")
    print("r:        \(Data(r).hexString)")
    print("s:        \(Data(s).hexString)")

} catch {
    print("ERROR: \(error)")
    exit(1)
}
