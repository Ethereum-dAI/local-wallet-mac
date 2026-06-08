import Foundation
import Testing
@testable import WalletMacOSApp

@Test func daemonConfigUsesHigherSepoliaGasCaps() throws {
    let toml = WalletNodeDaemon.daemonConfigTOML(chain: .ethereumSepolia)

    #expect(toml.contains(#"chain_id = 11155111"#))
    #expect(toml.contains(#"execution_rpc = "https://sepolia.drpc.org""#))
    #expect(toml.contains(#"consensus_rpc = "http://unstable.sepolia.beacon-api.nimbus.team""#))
    #expect(toml.contains(#"max_fee_per_gas = "0xba43b7400""#))
    #expect(toml.contains(#"max_priority_fee_per_gas = "0x12a05f200""#))
}

@Test func daemonConfigKeepsMainnetDefaultGasCaps() throws {
    let toml = WalletNodeDaemon.daemonConfigTOML(chain: .ethereum)

    #expect(toml.contains(#"chain_id = 1"#))
    #expect(toml.contains(#"max_fee_per_gas = "0x2540be400""#))
    #expect(toml.contains(#"max_priority_fee_per_gas = "0x3b9aca00""#))
}

@Test func daemonConfigIncludesPolicyDefaultsRequiredByWalletNode() throws {
    let toml = WalletNodeDaemon.daemonConfigTOML(chain: .ethereumSepolia)

    #expect(toml.contains("[policy]"))
    #expect(toml.contains(#"max_user_ops_per_bundle = 1"#))
    #expect(toml.contains(#"max_call_gas_limit = "0x989680""#))
    #expect(toml.contains(#"max_verification_gas_limit = "0x4c4b40""#))
    #expect(toml.contains(#"max_pre_verification_gas = "0x0f4240""#))
    #expect(toml.contains(#"min_replacement_bump_pct = 12.5"#))
    #expect(toml.contains(#"max_request_body_bytes = 262144"#))
    #expect(toml.contains(#"max_user_ops_per_sender_per_minute = 10"#))
    #expect(toml.contains(#"max_gas_wei_per_sender_per_hour = "0x0""#))
}

@Test func daemonConfigUsesCustomGasCaps() throws {
    let policy = try WalletNodeDaemon.GasPolicy.custom(
        maxFeePerGasGwei: "60",
        maxPriorityFeePerGasGwei: "2.5"
    )
    let toml = WalletNodeDaemon.daemonConfigTOML(chain: .ethereumSepolia, gasPolicy: policy)

    #expect(toml.contains(#"max_fee_per_gas = "0xdf8475800""#))
    #expect(toml.contains(#"max_priority_fee_per_gas = "0x9502f900""#))
}

@Test func gasPolicyRejectsPriorityAboveMax() throws {
    #expect(throws: WalletNodeDaemon.GasPolicyError.self) {
        _ = try WalletNodeDaemon.GasPolicy.custom(
            maxFeePerGasGwei: "1",
            maxPriorityFeePerGasGwei: "2"
        )
    }
}
