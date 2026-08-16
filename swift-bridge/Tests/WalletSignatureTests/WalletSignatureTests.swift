import XCTest
import CryptoKit
@testable import WalletSignature

final class WalletSignatureTests: XCTestCase {

    let entryPoint = Data(hexString: "0000000071727De22E5E9d8BAf0edAc6f37da032")!

    private func word(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { bytes in
            Data(repeating: 0, count: 24) + Data(bytes)
        }
    }

    func testAuthorizeUserOperationGasV1ReturnsCheckedLocalPlan() throws {
        let plan = try WalletSignature.authorizeUserOperationGasV1(
            sender: Data(repeating: 0x11, count: 20),
            nonce: word(7),
            initCode: Data(),
            callData: Data(repeating: 0x42, count: 96),
            callGasLimit: word(125_000),
            verificationGasLimit: word(250_000),
            maxFeePerGas: word(10_000_000_000),
            maxPriorityFeePerGas: word(1_000_000_000),
            paymasterAndData: Data(),
            signatureLength: 480,
            scope: .owner
        )

        XCTAssertEqual(plan.accountGasLimits.prefix(16), word(250_000).suffix(16))
        XCTAssertEqual(plan.accountGasLimits.suffix(16), word(125_000).suffix(16))
        XCTAssertEqual(plan.gasFees.prefix(16), word(1_000_000_000).suffix(16))
        XCTAssertEqual(plan.gasFees.suffix(16), word(10_000_000_000).suffix(16))
        XCTAssertNotEqual(plan.preVerificationGas, Data(repeating: 0, count: 32))
        XCTAssertNotEqual(plan.maxLiability, Data(repeating: 0, count: 32))
        XCTAssertEqual(plan.signatureLength, 480)
        XCTAssertEqual(plan.policyVersion, 1)
    }

    func testAuthorizeUserOperationGasV1RejectsMalformedWidthBeforeFFI() {
        XCTAssertThrowsError(
            try WalletSignature.authorizeUserOperationGasV1(
                sender: Data(repeating: 0x11, count: 19),
                nonce: word(7),
                initCode: Data(),
                callData: Data(),
                callGasLimit: word(1),
                verificationGasLimit: word(1),
                maxFeePerGas: word(1),
                maxPriorityFeePerGas: word(1),
                paymasterAndData: Data(),
                signatureLength: 65,
                scope: .owner
            )
        ) { error in
            XCTAssertEqual(error as? WalletGasAuthorizationError, .invalidInput)
        }
    }

    func testAuthorizeUserOperationGasV1RejectsCapPlusOneWithoutTruncation() {
        XCTAssertThrowsError(
            try WalletSignature.authorizeUserOperationGasV1(
                sender: Data(repeating: 0x11, count: 20),
                nonce: word(7),
                initCode: Data(),
                callData: Data(),
                callGasLimit: word(10_000_001),
                verificationGasLimit: word(1),
                maxFeePerGas: word(1),
                maxPriorityFeePerGas: word(1),
                paymasterAndData: Data(),
                signatureLength: 65,
                scope: .owner
            )
        ) { error in
            XCTAssertEqual(
                error as? WalletGasAuthorizationError,
                .capExceeded(field: "callGasLimit")
            )
        }
    }

    func testAuthorizeUserOperationGasV1RejectsMalformedSessionBudgetBeforeFFI() {
        XCTAssertThrowsError(
            try WalletSignature.authorizeUserOperationGasV1(
                sender: Data(repeating: 0x11, count: 20),
                nonce: word(7),
                initCode: Data(),
                callData: Data(),
                callGasLimit: word(1),
                verificationGasLimit: word(1),
                maxFeePerGas: word(1),
                maxPriorityFeePerGas: word(1),
                paymasterAndData: Data(),
                signatureLength: 65,
                scope: .session(gasBudget: Data(repeating: 0, count: 31))
            )
        ) { error in
            XCTAssertEqual(error as? WalletGasAuthorizationError, .invalidInput)
        }
    }

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

    func testOwnerDummyAndFinalSignatureLengthsMatchInBothVerifierModes() throws {
        let hash = Data(repeating: 0x42, count: 32)
        let r = Data(repeating: 0x11, count: 32)
        let s = Data(repeating: 0x22, count: 32)

        for usePrecompiled in [false, true] {
            let dummy = try WalletSignature.abiEncodeDummySignature(
                usePrecompiled: usePrecompiled
            )
            let final = try WalletSignature.abiEncodeSignature(
                userOpHash: hash,
                r: r,
                s: s,
                usePrecompiled: usePrecompiled
            )
            XCTAssertEqual(dummy.count, final.count)
        }
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

    func testBundlerAddressFromSecretMatchesPinnedVector() throws {
        let secret = Data(hexString: "4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9cc81287f7cf15d28b1ef")!
        let address = try WalletSignature.bundlerAddress(fromSecret: secret)

        XCTAssertEqual(address.hexString, "0xbe3f88b31963bedfdf8661eedf605639beaa0c4f")
    }

    func testSessionBuildPermissionReturnsPlan1FixtureShape() throws {
        let configJSON = Data("""
        {
          "account": "0x000000000000000000000000000000000000dEaD",
          "chainId": 11155111,
          "sessionKey": "0x90F8bf6A479f320ead074411a4B0e7944Ea8c9C1",
          "executeSelector": "0xe9ae5c53",
          "validationNonce": 1,
          "gasBudgetWei": "5000000000000000",
          "rateLimitIntervalSec": 86400,
          "rateLimitCount": 20,
          "rateLimitStartAt": 0,
          "validAfter": 0,
          "validUntil": 1900000000,
          "allowedCalls": [
            {
              "target": "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
              "selector": "0xa9059cbb",
              "valueLimitWei": "0",
              "rules": []
            },
            {
              "target": "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
              "selector": "0x095ea7b3",
              "valueLimitWei": "0",
              "rules": []
            }
          ]
        }
        """.utf8)

        let permission = try WalletSignature.sessionBuildPermission(configJSON: configJSON)

        XCTAssertEqual(permission.permissionId.hexString, "0x44366fcb")
        XCTAssertEqual(
            permission.enableDigest.hexString,
            "0x010bc9b9b04ad89b23fc5806dba26f3d3bdcf191cb6ff607d78287cf2d39cedd"
        )
        XCTAssertFalse(permission.enableData.isEmpty)
        XCTAssertEqual(permission.selectorData.prefix(4).hexString, "0xe9ae5c53")
        XCTAssertEqual(permission.nonceKeyDefault.count, 32)
        XCTAssertEqual(permission.nonceKeyEnable.count, 32)
        XCTAssertEqual(permission.nonceKeyDefault[8], 0x00)
        XCTAssertEqual(permission.nonceKeyDefault[9], 0x02)
        XCTAssertEqual(permission.nonceKeyEnable[8], 0x01)
        XCTAssertEqual(permission.nonceKeyEnable[9], 0x02)
    }

    func testSessionSignAndWrapInstalledMatchesPlan1Fixture() throws {
        let secret = Data(hexString: "4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9c46f30d7d21715b23b1d")!
        let hash = Data(hexString: "2d7b4ebae2de5315eaa3fb8edc341f76e683263012aca13c24eb63841d105852")!

        let signature = try WalletSignature.sessionSignAndWrap(
            secret: secret,
            userOpHash: hash,
            mode: .installed
        )

        XCTAssertEqual(
            signature.hexString,
            "0xffc7003f8ba4ba30856697a2b167be01b30eecd2ba3daa10c676b8839d31f204bd4641441d01eabd763428c80071e4722ff8012b13cc48a3c67f9d2ac02afc680f1c"
        )
    }

    func testSessionDummySignatureAndInvalidateNonceCalldata() throws {
        let dummy = try WalletSignature.sessionDummySignature(mode: .installed)
        XCTAssertEqual(dummy.count, 66)
        XCTAssertEqual(dummy[0], 0xff)

        let calldata = try WalletSignature.sessionInvalidateNonceCalldata(nonce: 7)
        XCTAssertEqual(
            calldata.hexString,
            "0x1f1b92e30000000000000000000000000000000000000000000000000000000000000007"
        )
    }

    func testInstalledSessionDummyAndFinalSignatureLengthsMatch() throws {
        let secret = Data(hexString: "4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9c46f30d7d21715b23b1d")!
        let hash = Data(repeating: 0x42, count: 32)
        let dummy = try WalletSignature.sessionDummySignature(mode: .installed)
        let final = try WalletSignature.sessionSignAndWrap(
            secret: secret,
            userOpHash: hash,
            mode: .installed
        )

        XCTAssertEqual(dummy.count, final.count)
    }

    func testEnableSessionDummyAndFinalSignatureLengthsMatchInBothVerifierModes() throws {
        let secret = Data(hexString: "4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9c46f30d7d21715b23b1d")!
        let hash = Data(repeating: 0x42, count: 32)
        let enableData = Data(repeating: 0x33, count: 96)
        let selectorData = Data(repeating: 0x44, count: 64)

        for usePrecompiled in [false, true] {
            let dummy = try WalletSignature.sessionDummySignature(
                mode: .enable,
                enableData: enableData,
                selectorData: selectorData,
                usePrecompiled: usePrecompiled
            )
            let rootEnableSignature = try WalletSignature.abiEncodeSignature(
                userOpHash: hash,
                r: Data(repeating: 0x11, count: 32),
                s: Data(repeating: 0x22, count: 32),
                usePrecompiled: usePrecompiled
            )
            let final = try WalletSignature.sessionSignAndWrap(
                secret: secret,
                userOpHash: hash,
                mode: .enable,
                enableData: enableData,
                selectorData: selectorData,
                enableSig: rootEnableSignature
            )

            XCTAssertEqual(dummy.count, final.count)
        }
    }

    func testSessionEmptyPermissionDeinitDataMatchesEnableEntryCount() throws {
        let enableData = Data(hexString:
            "0000000000000000000000000000000000000000000000000000000000000020"
                + "0000000000000000000000000000000000000000000000000000000000000005"
                + "00000000000000000000000000000000000000000000000000000000000000a0"
                + "00000000000000000000000000000000000000000000000000000000000000c0"
                + "00000000000000000000000000000000000000000000000000000000000000e0"
                + "0000000000000000000000000000000000000000000000000000000000000100"
                + "0000000000000000000000000000000000000000000000000000000000000120"
                + "0000000000000000000000000000000000000000000000000000000000000000"
                + "0000000000000000000000000000000000000000000000000000000000000000"
                + "0000000000000000000000000000000000000000000000000000000000000000"
                + "0000000000000000000000000000000000000000000000000000000000000000"
                + "0000000000000000000000000000000000000000000000000000000000000000"
        )!

        let deinitData = try WalletSignature.sessionEmptyPermissionDeinitData(enableData: enableData)

        XCTAssertEqual(deinitData, enableData)
    }

    func testSessionUninstallPermissionCalldataMatchesPinnedVector() throws {
        let calldata = try WalletSignature.sessionUninstallPermissionCalldata(
            permissionId: Data(hexString: "aabbccdd")!,
            deinitData: Data(hexString: "1234")!
        )

        XCTAssertEqual(
            calldata.hexString,
            "0xe6f3d50a"
                + "02aabbccdd000000000000000000000000000000000000000000000000000000"
                + "0000000000000000000000000000000000000000000000000000000000000060"
                + "00000000000000000000000000000000000000000000000000000000000000a0"
                + "0000000000000000000000000000000000000000000000000000000000000002"
                + "1234000000000000000000000000000000000000000000000000000000000000"
                + "0000000000000000000000000000000000000000000000000000000000000000"
        )
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
