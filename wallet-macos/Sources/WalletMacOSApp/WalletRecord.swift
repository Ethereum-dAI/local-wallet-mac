import Foundation

// WalletRecord is the persisted non-secret identity record for the demo wallet.
// It links the Keychain key tag to the derived public key and current smart-
// account metadata for the active demo chain.
struct WalletRecord: Codable, Equatable {
    let walletId: UUID
    let keyTag: String
    let pubkeyX: Data
    let pubkeyY: Data
    let chainId: UInt64
    let kernelAccountAddress: String?
    let authenticatorIdHash: Data
    let kernelSalt: Data
    let sessionRecords: [SessionRecord]
    let isDeployed: Bool
    let createdAt: Date
    let updatedAt: Date

    init(
        walletId: UUID,
        keyTag: String,
        pubkeyX: Data,
        pubkeyY: Data,
        chainId: UInt64,
        kernelAccountAddress: String?,
        authenticatorIdHash: Data = Data(repeating: 0, count: 32),
        kernelSalt: Data = Data(repeating: 0, count: 32),
        sessionRecords: [SessionRecord] = [],
        isDeployed: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.walletId = walletId
        self.keyTag = keyTag
        self.pubkeyX = pubkeyX
        self.pubkeyY = pubkeyY
        self.chainId = chainId
        self.kernelAccountAddress = kernelAccountAddress
        self.authenticatorIdHash = authenticatorIdHash
        self.kernelSalt = kernelSalt
        self.sessionRecords = sessionRecords
        self.isDeployed = isDeployed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case walletId
        case keyTag
        case pubkeyX
        case pubkeyY
        case chainId
        case kernelAccountAddress
        case authenticatorIdHash
        case kernelSalt
        case sessionRecords
        case isDeployed
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        walletId = try container.decode(UUID.self, forKey: .walletId)
        keyTag = try container.decode(String.self, forKey: .keyTag)
        pubkeyX = try container.decode(Data.self, forKey: .pubkeyX)
        pubkeyY = try container.decode(Data.self, forKey: .pubkeyY)
        chainId = try container.decode(UInt64.self, forKey: .chainId)
        kernelAccountAddress = try container.decodeIfPresent(String.self, forKey: .kernelAccountAddress)
        authenticatorIdHash = try container.decodeIfPresent(Data.self, forKey: .authenticatorIdHash)
            ?? Data(repeating: 0, count: 32)
        kernelSalt = try container.decodeIfPresent(Data.self, forKey: .kernelSalt)
            ?? Data(repeating: 0, count: 32)
        sessionRecords = try container.decodeIfPresent([SessionRecord].self, forKey: .sessionRecords) ?? []
        isDeployed = try container.decode(Bool.self, forKey: .isDeployed)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct PublicKeyCoordinates: Equatable {
    let x: Data
    let y: Data
}

extension PublicKeyCoordinates {
    init(x963Representation: Data) throws {
        guard x963Representation.count == 65, x963Representation.first == 0x04 else {
            throw AppError.invalidPublicKeyFormat
        }

        self.x = x963Representation.subdata(in: 1..<33)
        self.y = x963Representation.subdata(in: 33..<65)
    }
}

extension WalletRecord {
    func matches(_ coordinates: PublicKeyCoordinates) -> Bool {
        pubkeyX == coordinates.x && pubkeyY == coordinates.y
    }

    func replacingSessionRecord(
        _ sessionRecord: SessionRecord,
        isDeployed: Bool,
        updatedAt: Date
    ) -> WalletRecord {
        let retainedRecords = sessionRecords.filter { $0.chainId != sessionRecord.chainId }
        return WalletRecord(
            walletId: walletId,
            keyTag: keyTag,
            pubkeyX: pubkeyX,
            pubkeyY: pubkeyY,
            chainId: chainId,
            kernelAccountAddress: kernelAccountAddress,
            authenticatorIdHash: authenticatorIdHash,
            kernelSalt: kernelSalt,
            sessionRecords: retainedRecords + [sessionRecord],
            isDeployed: isDeployed,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func removingSessionRecord(
        chainID: UInt64,
        isDeployed: Bool,
        updatedAt: Date
    ) -> WalletRecord {
        WalletRecord(
            walletId: walletId,
            keyTag: keyTag,
            pubkeyX: pubkeyX,
            pubkeyY: pubkeyY,
            chainId: chainId,
            kernelAccountAddress: kernelAccountAddress,
            authenticatorIdHash: authenticatorIdHash,
            kernelSalt: kernelSalt,
            sessionRecords: sessionRecords.filter { $0.chainId != chainID },
            isDeployed: isDeployed,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func updatingSessionActivity(
        chainID: UInt64,
        activityAt: Date,
        isDeployed: Bool,
        updatedAt: Date
    ) -> WalletRecord {
        var refreshedRecords = sessionRecords
        guard let index = refreshedRecords.firstIndex(where: { $0.chainId == chainID }) else {
            return self
        }
        refreshedRecords[index].lastActivityAt = activityAt
        return WalletRecord(
            walletId: walletId,
            keyTag: keyTag,
            pubkeyX: pubkeyX,
            pubkeyY: pubkeyY,
            chainId: chainId,
            kernelAccountAddress: kernelAccountAddress,
            authenticatorIdHash: authenticatorIdHash,
            kernelSalt: kernelSalt,
            sessionRecords: refreshedRecords,
            isDeployed: isDeployed,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
