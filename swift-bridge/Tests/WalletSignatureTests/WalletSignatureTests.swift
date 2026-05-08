import XCTest
import CryptoKit
@testable import WalletSignature

final class WalletSignatureTests: XCTestCase {

    let entryPoint = Data(hexString: "0000000071727De22E5E9d8BAf0edAc6f37da032")!

    func testComputeUserOpHashReturns32Bytes() throws {
        let hash = try WalletSignature.computeUserOpHash(
            sender: Data(hexString: "d73c7780b1c1da1586a8332d5499f36b7cbb33c2")!,
            nonce: Data(hexString: "0000baac0ddb0000000000000000000000000000000000000000000000000001")!,
            initCode: Data(),
            callData: Data(),
            accountGasLimits: Data(repeating: 0, count: 32),
            preVerificationGas: Data(repeating: 0, count: 32),
            gasFees: Data(repeating: 0, count: 32),
            paymasterAndData: Data(),
            entryPoint: entryPoint,
            chainId: 1
        )
        XCTAssertEqual(hash.count, 32)
    }

    func testComputeSigningPreimageIs69Bytes() throws {
        let fakeHash = Data(repeating: 0x42, count: 32)
        let preimage = try WalletSignature.computeSigningPreimage(userOpHash: fakeHash)
        XCTAssertEqual(preimage.count, 69)
        XCTAssertEqual(preimage[32], 0x05) // flags byte
    }

    func testNormaliseLowSKeepsLowS() throws {
        var s = Data(hexString: "63bde20ed18273f1d59ae4411fa7abb4c929a4a7476e1934a04c4d4b05bad0e2")!
        let original = s
        try WalletSignature.normaliseLowS(s: &s)
        XCTAssertEqual(s, original, "already-low s should be unchanged")
    }

    func testAbiEncodeSignatureProducesAlignedOutput() throws {
        let hash = Data(repeating: 0x42, count: 32)
        let r = Data(repeating: 0x11, count: 32)
        let s = Data(repeating: 0x22, count: 32)
        let encoded = try WalletSignature.abiEncodeSignature(
            userOpHash: hash, r: r, s: s, usePrecompiled: true
        )
        XCTAssert(!encoded.isEmpty)
        XCTAssertEqual(encoded.count % 32, 0, "ABI encoding must be 32-byte aligned")
    }

    func testPredictKernelAccountAddressMatchesPinnedVector() throws {
        let predicted = try WalletSignature.predictKernelAccountAddress(
            factoryAddress: Data(hexString: "2577507b78c2008ff367261cb6285d44ba5ef2e9")!,
            implementation: Data(hexString: "d6cedde84be40893d153be9d467cd6ad37875b28")!,
            webauthnValidator: Data(hexString: "7ab16ff354acb328452f1d445b3ddee9a91e9e69")!,
            pubKeyX: Data(hexString: "0000000000000000000000000000000000000000000000000000000000000001")!,
            pubKeyY: Data(hexString: "0000000000000000000000000000000000000000000000000000000000000002")!,
            authenticatorIdHash: Data(repeating: 0, count: 32),
            salt: Data(repeating: 0, count: 32)
        )

        XCTAssertEqual(
            predicted.hexString,
            "0xea18d505d23f0b73a91409cd468aecf3beab03ba"
        )
    }

    func testGenerateBundlerSecretReturnsSecretAndAddress() throws {
        let generated = try WalletSignature.generateBundlerSecret()

        XCTAssertEqual(generated.secret.count, 32)
        XCTAssertEqual(generated.address.count, 20)
        XCTAssertNotEqual(generated.secret, Data(repeating: 0, count: 32))
        XCTAssertNotEqual(generated.address, Data(repeating: 0, count: 20))
    }

    func testFullPipeline() throws {
        // 1. Compute hash
        let hash = try WalletSignature.computeUserOpHash(
            sender: Data(repeating: 0xAA, count: 20),
            nonce: Data(repeating: 0, count: 32),
            initCode: Data(),
            callData: Data(),
            accountGasLimits: Data(repeating: 0, count: 32),
            preVerificationGas: Data(repeating: 0, count: 32),
            gasFees: Data(repeating: 0, count: 32),
            paymasterAndData: Data(),
            entryPoint: entryPoint,
            chainId: 1
        )

        // 2. Get preimage (69 bytes for CryptoKit)
        let preimage = try WalletSignature.computeSigningPreimage(userOpHash: hash)
        XCTAssertEqual(preimage.count, 69)

        // 3. Sign with a test P-256 key (NOT Secure Enclave — just CryptoKit in software)
        let privateKey = P256.Signing.PrivateKey()
        let signature = try privateKey.signature(for: preimage)
        let rawSig = signature.rawRepresentation
        let r = Data(rawSig[0..<32])
        var s = Data(rawSig[32..<64])

        // 4. Normalise low-s
        try WalletSignature.normaliseLowS(s: &s)

        // 5. ABI encode
        let encoded = try WalletSignature.abiEncodeSignature(
            userOpHash: hash, r: r, s: s, usePrecompiled: true
        )
        XCTAssert(!encoded.isEmpty)
        XCTAssertEqual(encoded.count % 32, 0)
    }
}

// Hex utility for tests
extension Data {
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
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
        "0x" + map { String(format: "%02x", $0) }.joined()
    }
}
