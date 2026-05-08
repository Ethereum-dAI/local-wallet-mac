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

public struct WalletSignature {
    public struct BundlerSecret {
        public let secret: Data
        public let address: Data
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
