import Foundation
import LocalAuthentication
import Security
import Testing
@testable import WalletMacOSApp

private final class ProvisioningSecurityItemClient: SecurityItemClient, @unchecked Sendable {
    struct Response {
        let status: OSStatus
        let result: Any?
    }

    private let lock = NSLock()
    private var addResponses: [Response]
    private var copyResponses: [Response]
    private var deleteStatuses: [OSStatus]
    private(set) var additions: [[String: Any]] = []
    private(set) var copies: [[String: Any]] = []
    private(set) var deletions: [[String: Any]] = []

    init(
        addResponses: [Response] = [],
        copyResponses: [Response] = [],
        deleteStatuses: [OSStatus] = []
    ) {
        self.addResponses = addResponses
        self.copyResponses = copyResponses
        self.deleteStatuses = deleteStatuses
    }

    func add(_ attributes: [String: Any]) -> (status: OSStatus, result: Any?) {
        lock.withLock {
            additions.append(attributes)
            guard addResponses.isEmpty == false else { return (errSecSuccess, nil) }
            let response = addResponses.removeFirst()
            return (response.status, response.result)
        }
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        lock.withLock {
            copies.append(query)
            guard copyResponses.isEmpty == false else { return (errSecItemNotFound, nil) }
            let response = copyResponses.removeFirst()
            return (response.status, response.result)
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            deletions.append(query)
            return deleteStatuses.isEmpty ? errSecSuccess : deleteStatuses.removeFirst()
        }
    }
}

@Suite(.serialized)
struct RelayerProvisioningPromptBudgetTests {
    private let chain = ChainConfiguration.ethereumSepolia
    private let keyRef = "bundler-eoa:default:11155111:1"

    @Test func freshWinnerPerformsZeroProtectedReads() throws {
        let generatedSecret = Data(repeating: 0x11, count: 32)
        let protectedClient = ProvisioningSecurityItemClient(
            addResponses: [.init(status: errSecSuccess, result: nil)]
        )
        let publicClient = ProvisioningSecurityItemClient(
            addResponses: [.init(status: errSecSuccess, result: nil)]
        )
        let service = makeService(
            protectedClient: protectedClient,
            publicClient: publicClient,
            generatedSecret: generatedSecret
        )
        let context = LAContext()

        let result = try service.createOrLoadBundlerIdentity(authenticationContext: context)

        #expect(result.record.secret == generatedSecret)
        #expect(result.identity == (try VerifiedRelayerIdentity.derive(
            keyRef: keyRef,
            secret: generatedSecret
        )))
        #expect(protectedClient.additions.count == 1)
        #expect(protectedClient.copies.isEmpty)
        #expect(publicClient.additions.count == 1)
    }

    @Test func existingWinnerPerformsOneProtectedReadWithExactCallerContext() throws {
        let generatedLoser = Data(repeating: 0x11, count: 32)
        let canonicalWinner = Data(repeating: 0x22, count: 32)
        let protectedClient = ProvisioningSecurityItemClient(
            addResponses: [.init(status: errSecDuplicateItem, result: nil)],
            copyResponses: [.init(status: errSecSuccess, result: [
                kSecValueData as String: canonicalWinner,
            ])]
        )
        let publicClient = ProvisioningSecurityItemClient(
            addResponses: [.init(status: errSecSuccess, result: nil)]
        )
        let service = makeService(
            protectedClient: protectedClient,
            publicClient: publicClient,
            generatedSecret: generatedLoser
        )
        let context = LAContext()

        let result = try service.createOrLoadBundlerIdentity(authenticationContext: context)

        #expect(result.record.secret == canonicalWinner)
        #expect(result.record.secret != generatedLoser)
        #expect(protectedClient.copies.count == 1)
        let query = try #require(protectedClient.copies.first)
        #expect(query[kSecUseAuthenticationContext as String] as? LAContext === context)
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(publicClient.additions.count == 1)
    }

    @Test func cancelledExistingReadDoesNotRetry() throws {
        let protectedClient = ProvisioningSecurityItemClient(
            addResponses: [.init(status: errSecDuplicateItem, result: nil)],
            copyResponses: [.init(status: errSecUserCanceled, result: nil)]
        )
        let publicClient = ProvisioningSecurityItemClient()
        let service = makeService(
            protectedClient: protectedClient,
            publicClient: publicClient,
            generatedSecret: Data(repeating: 0x11, count: 32)
        )
        let context = LAContext()

        #expect(throws: AppError.self) {
            _ = try service.createOrLoadBundlerIdentity(authenticationContext: context)
        }
        #expect(protectedClient.copies.count == 1)
        #expect(publicClient.additions.isEmpty)
    }

    @Test func publicIdentityConflictFailsClosedWithoutProtectedRead() throws {
        let generatedSecret = Data(repeating: 0x11, count: 32)
        let conflicting = try VerifiedRelayerIdentity(
            chainID: chain.id,
            keyRef: keyRef,
            address: "0x2222222222222222222222222222222222222222"
        )
        let protectedClient = ProvisioningSecurityItemClient(
            addResponses: [.init(status: errSecSuccess, result: nil)]
        )
        let publicClient = ProvisioningSecurityItemClient(
            addResponses: [.init(status: errSecDuplicateItem, result: nil)],
            copyResponses: [.init(
                status: errSecSuccess,
                result: try conflicting.encodedMetadata()
            )]
        )
        let service = makeService(
            protectedClient: protectedClient,
            publicClient: publicClient,
            generatedSecret: generatedSecret
        )

        #expect(throws: RelayerPublicIdentityStore.StoreError.conflictingIdentity(keyRef)) {
            _ = try service.createOrLoadBundlerIdentity(authenticationContext: LAContext())
        }
        #expect(protectedClient.copies.isEmpty)
    }

    @Test func registrationFinalizationAppendsGenesisThenPassivelyReadsAuthorityBack() throws {
        let identity = try VerifiedRelayerIdentity.derive(
            keyRef: keyRef,
            secret: Data(repeating: 0x11, count: 32)
        )
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chain.id,
            activeKeyRef: keyRef
        )
        let publicClient = ProvisioningSecurityItemClient(copyResponses: [
            .init(status: errSecSuccess, result: try identity.encodedMetadata()),
        ])
        let journalClient = ProvisioningSecurityItemClient(
            addResponses: [.init(status: errSecSuccess, result: nil)],
            copyResponses: [
                .init(status: errSecItemNotFound, result: nil),
                .init(status: errSecItemNotFound, result: nil),
                .init(status: errSecSuccess, result: [try journalItem(genesis)]),
            ]
        )
        let service = makeService(
            protectedClient: ProvisioningSecurityItemClient(),
            publicClient: publicClient,
            journalClient: journalClient,
            generatedSecret: Data(repeating: 0x11, count: 32)
        )

        #expect(try service.finalizeRegisteredBundlerIdentity(identity) == identity)
        #expect(journalClient.additions.count == 1)
        #expect(journalClient.copies.count == 3)
        #expect(publicClient.copies.count == 1)
    }

    @Test func registrationFinalizationAcceptsOnlyTheExactExistingHead() throws {
        let identity = try VerifiedRelayerIdentity.derive(
            keyRef: keyRef,
            secret: Data(repeating: 0x11, count: 32)
        )
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chain.id,
            activeKeyRef: keyRef
        )
        let item = try journalItem(genesis)
        let publicClient = ProvisioningSecurityItemClient(copyResponses: [
            .init(status: errSecSuccess, result: try identity.encodedMetadata()),
        ])
        let journalClient = ProvisioningSecurityItemClient(copyResponses: [
            .init(status: errSecSuccess, result: [item]),
            .init(status: errSecSuccess, result: [item]),
        ])
        let service = makeService(
            protectedClient: ProvisioningSecurityItemClient(),
            publicClient: publicClient,
            journalClient: journalClient,
            generatedSecret: Data(repeating: 0x11, count: 32)
        )

        #expect(try service.finalizeRegisteredBundlerIdentity(identity) == identity)
        #expect(journalClient.additions.isEmpty)
        #expect(journalClient.copies.count == 2)
        #expect(publicClient.copies.count == 1)
    }

    @Test func registrationFinalizationFailsBeforePublicationWhenReadbackDisappears() throws {
        let identity = try VerifiedRelayerIdentity.derive(
            keyRef: keyRef,
            secret: Data(repeating: 0x11, count: 32)
        )
        let journalClient = ProvisioningSecurityItemClient(
            addResponses: [.init(status: errSecSuccess, result: nil)],
            copyResponses: [
                .init(status: errSecItemNotFound, result: nil),
                .init(status: errSecItemNotFound, result: nil),
                .init(status: errSecItemNotFound, result: nil),
            ]
        )
        let service = makeService(
            protectedClient: ProvisioningSecurityItemClient(),
            publicClient: ProvisioningSecurityItemClient(),
            journalClient: journalClient,
            generatedSecret: Data(repeating: 0x11, count: 32)
        )

        #expect(throws: OnboardingRelayerProvisioningError.finalJournalReadbackMissing(chain.id)) {
            _ = try service.finalizeRegisteredBundlerIdentity(identity)
        }
    }

    private func makeService(
        protectedClient: ProvisioningSecurityItemClient,
        publicClient: ProvisioningSecurityItemClient,
        journalClient: ProvisioningSecurityItemClient = ProvisioningSecurityItemClient(),
        generatedSecret: Data
    ) -> OnboardingProvisioningService {
        let suiteName = "RelayerProvisioningPromptBudgetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let publicStore = RelayerPublicIdentityStore(client: publicClient)
        return OnboardingProvisioningService(
            settingsStore: OnboardingSettingsStore(defaults: defaults),
            chain: chain,
            bundlerKeyStore: BundlerKeyStore(
                client: protectedClient,
                publicIdentityStore: publicStore
            ),
            relayerPublicIdentityStore: publicStore,
            relayerChainStateJournalStore: RelayerChainStateJournalStore(
                client: journalClient
            ),
            generateBundlerSecret: { generatedSecret }
        )
    }

    private func journalItem(_ state: RelayerChainState) throws -> [String: Any] {
        [
            kSecAttrAccount as String: RelayerChainStateJournalStore.account(
                chainID: state.chainID,
                epoch: state.epoch
            ),
            kSecValueData as String: try state.canonicalEncoding(),
        ]
    }
}
