import Foundation

// This file centralizes demo-chain configuration: RPCs, bundlers, EntryPoint,
// Kernel contract addresses, and the ABI files that the app ships with.
struct KernelContractAddresses: Equatable {
    let factory: String
    let implementation: String
    let webAuthnValidator: String
}

struct ABIResource: Equatable {
    let fileName: String
}

struct ChainConfiguration: Equatable {
    let id: UInt64
    let name: String
    let shortName: String
    let rpcURL: URL
    let archiveRPCURL: URL?
    let consensusRPCURL: URL?
    let bundlerURL: URL?
    let entryPoint: String
    let kernel: KernelContractAddresses
    let abiResources: [ABIResource]

    private static let bundlerURLEnvironmentKey = "LOCAL_WALLET_SEPOLIA_BUNDLER_URL"
    private static let bundlerURLInfoPlistKey = "LocalWalletSepoliaBundlerURL"

    static let ethereumSepolia = ChainConfiguration(
        id: 11_155_111,
        name: "Ethereum Sepolia",
        shortName: "sepolia",
        rpcURL: URL(string: "https://ethereum-sepolia-rpc.publicnode.com")!,
        archiveRPCURL: nil,
        consensusRPCURL: URL(string: "http://unstable.sepolia.beacon-api.nimbus.team")!,
        bundlerURL: configuredSepoliaBundlerURL(),
        entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
        kernel: KernelContractAddresses(
            factory: "0x2577507b78c2008Ff367261CB6285d44ba5eF2E9",
            implementation: "0xd6CEDDe84be40893d153Be9d467CD6aD37875b28",
            webAuthnValidator: "0x7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69"
        ),
        abiResources: ABIResource.defaultSet
    )

    private static func configuredSepoliaBundlerURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment[bundlerURLEnvironmentKey]
        if let url = normalizedURL(from: environment) {
            return url
        }

        let infoPlist = Bundle.main.object(forInfoDictionaryKey: bundlerURLInfoPlistKey) as? String
        return normalizedURL(from: infoPlist)
    }

    private static func normalizedURL(from rawValue: String?) -> URL? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        return URL(string: trimmed)
    }

    func overridingNetworkURLs(
        rpcURL: URL,
        archiveRPCURL: URL?,
        consensusRPCURL: URL?
    ) -> ChainConfiguration {
        ChainConfiguration(
            id: id,
            name: name,
            shortName: shortName,
            rpcURL: rpcURL,
            archiveRPCURL: archiveRPCURL,
            consensusRPCURL: consensusRPCURL,
            bundlerURL: bundlerURL,
            entryPoint: entryPoint,
            kernel: kernel,
            abiResources: abiResources
        )
    }
}

extension ABIResource {
    static let defaultSet: [ABIResource] = [
        ABIResource(fileName: "KernelFactory.json"),
        ABIResource(fileName: "KernelImplementation.json"),
        ABIResource(fileName: "WebAuthnValidator.json"),
    ]
}

struct DemoAppConfiguration {
    let networkSettings: DemoNetworkSettings

    var activeChain: ChainConfiguration {
        networkSettings.activeChain
    }
}
