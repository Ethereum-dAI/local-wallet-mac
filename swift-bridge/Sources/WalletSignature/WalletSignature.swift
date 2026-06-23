import Foundation
import WalletFFI

public enum WalletError: Error {
    case invalidInput
    case internalError
}

private func checkResult(_ code: Int32) throws {
    switch code {
    case 0: return
    case -1: throw WalletError.invalidInput
    default: throw WalletError.internalError
    }
}

private func takeFFIBuffer(_ ptr: UnsafePointer<UInt8>?, _ len: UInt32) throws -> Data {
    guard let ptr, len > 0 else {
        throw WalletError.internalError
    }
    let data = Data(bytes: ptr, count: Int(len))
    wallet_free_buffer(UnsafeMutablePointer(mutating: ptr), len)
    return data
}

public struct WalletSignature {
    public enum SessionSignatureMode: UInt8 {
        case installed = 0
        case enable = 1
    }

    public struct BundlerSecret {
        public let secret: Data
        public let address: Data
    }

    public struct SessionPermission {
        public let permissionId: Data
        public let enableData: Data
        public let enableDigest: Data
        public let selectorData: Data
        public let nonceKeyDefault: Data
        public let nonceKeyEnable: Data
    }

    public static func generateBundlerSecret() throws -> BundlerSecret {
        var secret = Data(count: 32)
        var address = Data(count: 20)
        let result = secret.withUnsafeMutableBytes { secretPtr in
            address.withUnsafeMutableBytes { addressPtr in
                wallet_generate_bundler_secret(
                    secretPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    addressPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
        try checkResult(result)
        return BundlerSecret(secret: secret, address: address)
    }

    public static func bundlerAddress(fromSecret secret: Data) throws -> Data {
        guard secret.count == 32 else {
            throw WalletError.invalidInput
        }

        var address = Data(count: 20)
        let result = secret.withUnsafeBytes { secretPtr in
            address.withUnsafeMutableBytes { addressPtr in
                wallet_bundler_address_from_secret(
                    secretPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    addressPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
        try checkResult(result)
        return address
    }

    public static func computeUserOpHash(
        sender: Data,
        nonce: Data,
        initCode: Data,
        callData: Data,
        accountGasLimits: Data,
        preVerificationGas: Data,
        gasFees: Data,
        paymasterAndData: Data,
        entryPoint: Data,
        chainId: UInt64
    ) throws -> Data {
        var out = Data(count: 32)
        let result = out.withUnsafeMutableBytes { outPtr in
            sender.withUnsafeBytes { senderPtr in
                nonce.withUnsafeBytes { noncePtr in
                    initCode.withUnsafeBytes { icPtr in
                        callData.withUnsafeBytes { cdPtr in
                            accountGasLimits.withUnsafeBytes { aglPtr in
                                preVerificationGas.withUnsafeBytes { pvgPtr in
                                    gasFees.withUnsafeBytes { gfPtr in
                                        paymasterAndData.withUnsafeBytes { pmPtr in
                                            entryPoint.withUnsafeBytes { epPtr in
                                                wallet_compute_userop_hash(
                                                    senderPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                    noncePtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                    icPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                    UInt32(initCode.count),
                                                    cdPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                    UInt32(callData.count),
                                                    aglPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                    pvgPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                    gfPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                    pmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                    UInt32(paymasterAndData.count),
                                                    epPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                    chainId,
                                                    outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        try checkResult(result)
        return out
    }

    public static func computeSigningPreimage(userOpHash: Data) throws -> Data {
        var out = Data(count: 69)
        let result = userOpHash.withUnsafeBytes { hashPtr in
            out.withUnsafeMutableBytes { outPtr in
                wallet_compute_signing_preimage(
                    hashPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
        try checkResult(result)
        return out
    }

    public static func normaliseLowS(s: inout Data) throws {
        let result = s.withUnsafeMutableBytes { sPtr in
            wallet_normalise_low_s(
                sPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
            )
        }
        try checkResult(result)
    }

    public static func abiEncodeSignature(
        userOpHash: Data,
        r: Data,
        s: Data,
        usePrecompiled: Bool
    ) throws -> Data {
        var outPtr: UnsafePointer<UInt8>?
        var outLen: UInt32 = 0

        let result = userOpHash.withUnsafeBytes { hashPtr in
            r.withUnsafeBytes { rPtr in
                s.withUnsafeBytes { sPtr in
                    wallet_abi_encode_signature(
                        hashPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        rPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        sPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        usePrecompiled,
                        &outPtr,
                        &outLen
                    )
                }
            }
        }
        try checkResult(result)

        guard let ptr = outPtr, outLen > 0 else {
            throw WalletError.internalError
        }

        let data = Data(bytes: ptr, count: Int(outLen))
        wallet_free_buffer(UnsafeMutablePointer(mutating: ptr), outLen)
        return data
    }

    public static func abiEncodeDummySignature(
        usePrecompiled: Bool
    ) throws -> Data {
        var outPtr: UnsafePointer<UInt8>?
        var outLen: UInt32 = 0

        let result = wallet_abi_encode_dummy_signature(
            usePrecompiled,
            &outPtr,
            &outLen
        )
        try checkResult(result)

        guard let ptr = outPtr, outLen > 0 else {
            throw WalletError.internalError
        }

        let data = Data(bytes: ptr, count: Int(outLen))
        wallet_free_buffer(UnsafeMutablePointer(mutating: ptr), outLen)
        return data
    }

    public static func sessionBuildPermission(configJSON: Data) throws -> SessionPermission {
        guard !configJSON.isEmpty else {
            throw WalletError.invalidInput
        }

        var permissionId = Data(count: 4)
        var enableDigest = Data(count: 32)
        var nonceKeyDefault = Data(count: 32)
        var nonceKeyEnable = Data(count: 32)
        var enableDataPtr: UnsafePointer<UInt8>?
        var enableDataLen: UInt32 = 0
        var selectorDataPtr: UnsafePointer<UInt8>?
        var selectorDataLen: UInt32 = 0

        let result: Int32 = configJSON.withUnsafeBytes { configPtr in
            permissionId.withUnsafeMutableBytes { permissionPtr in
                enableDigest.withUnsafeMutableBytes { digestPtr in
                    nonceKeyDefault.withUnsafeMutableBytes { defaultPtr in
                        nonceKeyEnable.withUnsafeMutableBytes { enablePtr in
                            wallet_session_build_permission(
                                configPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                UInt32(configJSON.count),
                                permissionPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                &enableDataPtr,
                                &enableDataLen,
                                &selectorDataPtr,
                                &selectorDataLen,
                                digestPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                defaultPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                enablePtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                            )
                        }
                    }
                }
            }
        }
        try checkResult(result)

        let enableData = try takeFFIBuffer(enableDataPtr, enableDataLen)
        let selectorData = try takeFFIBuffer(selectorDataPtr, selectorDataLen)
        return SessionPermission(
            permissionId: permissionId,
            enableData: enableData,
            enableDigest: enableDigest,
            selectorData: selectorData,
            nonceKeyDefault: nonceKeyDefault,
            nonceKeyEnable: nonceKeyEnable
        )
    }

    public static func sessionSignAndWrap(
        secret: Data,
        userOpHash: Data,
        mode: SessionSignatureMode,
        enableData: Data = Data(),
        selectorData: Data = Data(),
        enableSig: Data = Data()
    ) throws -> Data {
        guard secret.count == 32, userOpHash.count == 32 else {
            throw WalletError.invalidInput
        }

        var outPtr: UnsafePointer<UInt8>?
        var outLen: UInt32 = 0

        let result: Int32
        switch mode {
        case .installed:
            result = secret.withUnsafeBytes { secretPtr in
                userOpHash.withUnsafeBytes { hashPtr in
                    wallet_session_sign_and_wrap(
                        secretPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        hashPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        mode.rawValue,
                        nil,
                        0,
                        nil,
                        0,
                        nil,
                        0,
                        &outPtr,
                        &outLen
                    )
                }
            }
        case .enable:
            guard !enableData.isEmpty, !selectorData.isEmpty, !enableSig.isEmpty else {
                throw WalletError.invalidInput
            }
            result = secret.withUnsafeBytes { secretPtr in
                userOpHash.withUnsafeBytes { hashPtr in
                    enableData.withUnsafeBytes { enableDataPtr in
                        selectorData.withUnsafeBytes { selectorDataPtr in
                            enableSig.withUnsafeBytes { enableSigPtr in
                                wallet_session_sign_and_wrap(
                                    secretPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    hashPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    mode.rawValue,
                                    enableDataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    UInt32(enableData.count),
                                    selectorDataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    UInt32(selectorData.count),
                                    enableSigPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    UInt32(enableSig.count),
                                    &outPtr,
                                    &outLen
                                )
                            }
                        }
                    }
                }
            }
        }

        try checkResult(result)
        return try takeFFIBuffer(outPtr, outLen)
    }

    public static func sessionDummySignature(
        mode: SessionSignatureMode,
        enableData: Data = Data(),
        selectorData: Data = Data(),
        usePrecompiled: Bool = false
    ) throws -> Data {
        var outPtr: UnsafePointer<UInt8>?
        var outLen: UInt32 = 0

        let result: Int32
        switch mode {
        case .installed:
            result = wallet_session_dummy_signature(
                mode.rawValue,
                nil,
                0,
                nil,
                0,
                usePrecompiled,
                &outPtr,
                &outLen
            )
        case .enable:
            guard !enableData.isEmpty, !selectorData.isEmpty else {
                throw WalletError.invalidInput
            }
            result = enableData.withUnsafeBytes { enableDataPtr in
                selectorData.withUnsafeBytes { selectorDataPtr in
                    wallet_session_dummy_signature(
                        mode.rawValue,
                        enableDataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        UInt32(enableData.count),
                        selectorDataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        UInt32(selectorData.count),
                        usePrecompiled,
                        &outPtr,
                        &outLen
                    )
                }
            }
        }

        try checkResult(result)
        return try takeFFIBuffer(outPtr, outLen)
    }

    public static func sessionInvalidateNonceCalldata(nonce: UInt32) throws -> Data {
        var outPtr: UnsafePointer<UInt8>?
        var outLen: UInt32 = 0

        let result = wallet_session_invalidate_nonce_calldata(nonce, &outPtr, &outLen)
        try checkResult(result)
        return try takeFFIBuffer(outPtr, outLen)
    }

    public static func sessionEmptyPermissionDeinitData(enableData: Data) throws -> Data {
        guard !enableData.isEmpty else {
            throw WalletError.invalidInput
        }

        var outPtr: UnsafePointer<UInt8>?
        var outLen: UInt32 = 0

        let result = enableData.withUnsafeBytes { enableDataPtr in
            wallet_session_empty_permission_deinit_data(
                enableDataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt32(enableData.count),
                &outPtr,
                &outLen
            )
        }
        try checkResult(result)
        return try takeFFIBuffer(outPtr, outLen)
    }

    public static func sessionUninstallPermissionCalldata(
        permissionId: Data,
        deinitData: Data = Data()
    ) throws -> Data {
        guard permissionId.count == 4 else {
            throw WalletError.invalidInput
        }

        var outPtr: UnsafePointer<UInt8>?
        var outLen: UInt32 = 0

        let result = permissionId.withUnsafeBytes { permissionPtr in
            deinitData.withUnsafeBytes { deinitPtr in
                wallet_session_uninstall_permission_calldata(
                    permissionPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    deinitPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    UInt32(deinitData.count),
                    &outPtr,
                    &outLen
                )
            }
        }
        try checkResult(result)
        return try takeFFIBuffer(outPtr, outLen)
    }

    public static func sessionInstallValidationsCalldata(
        permissionId: Data,
        nonce: UInt32,
        validationData: Data,
        hookData: Data = Data()
    ) throws -> Data {
        guard permissionId.count == 4 else {
            throw WalletError.invalidInput
        }

        var outPtr: UnsafePointer<UInt8>?
        var outLen: UInt32 = 0

        let result = permissionId.withUnsafeBytes { permissionPtr in
            validationData.withUnsafeBytes { validationPtr in
                hookData.withUnsafeBytes { hookPtr in
                    wallet_session_install_validations_calldata(
                        permissionPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        nonce,
                        validationPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        UInt32(validationData.count),
                        hookPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        UInt32(hookData.count),
                        &outPtr,
                        &outLen
                    )
                }
            }
        }
        try checkResult(result)
        return try takeFFIBuffer(outPtr, outLen)
    }

    public static func sessionGrantAccessCalldata(
        permissionId: Data,
        selector: Data
    ) throws -> Data {
        guard permissionId.count == 4, selector.count == 4 else {
            throw WalletError.invalidInput
        }

        var outPtr: UnsafePointer<UInt8>?
        var outLen: UInt32 = 0

        let result = permissionId.withUnsafeBytes { permissionPtr in
            selector.withUnsafeBytes { selectorPtr in
                wallet_session_grant_access_calldata(
                    permissionPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    selectorPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    &outPtr,
                    &outLen
                )
            }
        }
        try checkResult(result)
        return try takeFFIBuffer(outPtr, outLen)
    }

    public static func predictKernelAccountAddress(
        factoryAddress: Data,
        implementation: Data,
        webauthnValidator: Data,
        pubKeyX: Data,
        pubKeyY: Data,
        authenticatorIdHash: Data,
        salt: Data
    ) throws -> Data {
        var out = Data(count: 20)
        let result: Int32 = out.withUnsafeMutableBytes { outPtr in
            let outBase = outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return factoryAddress.withUnsafeBytes { factoryPtr in
                let factoryBase = factoryPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return implementation.withUnsafeBytes { implementationPtr in
                    let implementationBase = implementationPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    return webauthnValidator.withUnsafeBytes { validatorPtr in
                        let validatorBase = validatorPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                        return pubKeyX.withUnsafeBytes { xPtr in
                            let xBase = xPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                            return pubKeyY.withUnsafeBytes { yPtr in
                                let yBase = yPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                                return authenticatorIdHash.withUnsafeBytes { authPtr in
                                    let authBase = authPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                                    return salt.withUnsafeBytes { saltPtr in
                                        let saltBase = saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                                        return wallet_predict_kernel_account_address(
                                            factoryBase,
                                            implementationBase,
                                            validatorBase,
                                            xBase,
                                            yBase,
                                            authBase,
                                            saltBase,
                                            outBase
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        try checkResult(result)
        return out
    }

    public static func encodeKernelInitializeCall(
        webauthnValidator: Data,
        pubKeyX: Data,
        pubKeyY: Data,
        authenticatorIdHash: Data
    ) throws -> Data {
        var outPtr: UnsafePointer<UInt8>?
        var outLen: UInt32 = 0

        let result: Int32 = webauthnValidator.withUnsafeBytes { validatorPtr in
            let validatorBase = validatorPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return pubKeyX.withUnsafeBytes { xPtr in
                let xBase = xPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return pubKeyY.withUnsafeBytes { yPtr in
                    let yBase = yPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    return authenticatorIdHash.withUnsafeBytes { authPtr in
                        let authBase = authPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                        return wallet_encode_kernel_initialize_call(
                            validatorBase,
                            xBase,
                            yBase,
                            authBase,
                            &outPtr,
                            &outLen
                        )
                    }
                }
            }
        }

        try checkResult(result)

        guard let ptr = outPtr, outLen > 0 else {
            throw WalletError.internalError
        }

        let data = Data(bytes: ptr, count: Int(outLen))
        wallet_free_buffer(UnsafeMutablePointer(mutating: ptr), outLen)
        return data
    }
}
