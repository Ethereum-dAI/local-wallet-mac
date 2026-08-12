import Darwin
import Foundation
import Testing
@testable import SpawnHelper
@testable import WalletMacOSApp

@Test func releaseHelperCandidatesIgnoreEnvironmentAndSourceTree() {
    let resources = URL(fileURLWithPath: "/Applications/LocalWallet.app/Contents/Resources")
    let sourceRoot = URL(fileURLWithPath: "/tmp/local-wallet-source")
    let environment = [
        "LOCAL_WALLET_NODE_BIN": "/tmp/attacker-wallet-node",
        "WALLET_NODE_BIN": "/tmp/other-wallet-node",
        "RAILGUN_HELPER_BIN": "/tmp/attacker-railgun-helper",
        "LOCAL_WALLET_PRIVACY_BIN": "/tmp/other-railgun-helper",
    ]

    #expect(
        TrustedHelperExecutableResolver.candidateURLs(
            for: .walletNode,
            environment: environment,
            mode: .release,
            bundleResourceURL: resources,
            sourceRootURL: sourceRoot
        ) == [resources.appendingPathComponent("bin/wallet-node")]
    )
    #expect(
        TrustedHelperExecutableResolver.candidateURLs(
            for: .railgunHelper,
            environment: environment,
            mode: .release,
            bundleResourceURL: resources,
            sourceRootURL: sourceRoot
        ) == [resources.appendingPathComponent("bin/railgun-helper")]
    )
}

#if DEBUG
@Test func debugHelperCandidatesPreserveLocalDevelopmentOverrides() {
    let resources = URL(fileURLWithPath: "/Applications/LocalWallet.app/Contents/Resources")
    let sourceRoot = URL(fileURLWithPath: "/tmp/local-wallet-source")
    let candidates = TrustedHelperExecutableResolver.candidateURLs(
        for: .walletNode,
        environment: ["LOCAL_WALLET_NODE_BIN": "/tmp/development-wallet-node"],
        mode: .debug,
        bundleResourceURL: resources,
        sourceRootURL: sourceRoot
    )

    #expect(candidates.first?.path == "/tmp/development-wallet-node")
    #expect(candidates.contains(resources.appendingPathComponent("bin/wallet-node")))
    #expect(candidates.contains(sourceRoot.appendingPathComponent("local-wallet-daemon/target/release/wallet-node")))
    #expect(candidates.contains(sourceRoot.appendingPathComponent("local-wallet-daemon/target/debug/wallet-node")))
}
#endif

@Test func bundledHelperPathRejectsSymlinks() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("trusted-helper-path-\(UUID().uuidString)", isDirectory: true)
    let resources = root.appendingPathComponent("Resources", isDirectory: true)
    let bin = resources.appendingPathComponent("bin", isDirectory: true)
    let realHelper = root.appendingPathComponent("wallet-node-real")
    let bundledHelper = bin.appendingPathComponent("wallet-node")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("helper".utf8).write(to: realHelper)
    #expect(chmod(realHelper.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0)
    try FileManager.default.createSymbolicLink(at: bundledHelper, withDestinationURL: realHelper)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: TrustedHelperTrustError.self) {
        _ = try TrustedHelperExecutableResolver.validateBundledExecutableURL(
            for: .walletNode,
            bundleResourceURL: resources
        )
    }
}

@Test func trustedHelperManifestPinsPathIdentifierHashAndTeam() throws {
    let data = Data(
        #"{"schemaVersion":1,"helpers":{"wallet-node":{"relativePath":"bin/wallet-node","identifier":"ai.ethereum.localwallet.wallet-node","cdHash":"00112233445566778899aabbccddeeff00112233","teamIdentifier":"ABCDEFGHIJ"}}}"#.utf8
    )

    let entry = try TrustedHelperExecutableResolver.manifestEntry(
        for: .walletNode,
        data: data,
        outerAppTeamIdentifier: "ABCDEFGHIJ"
    )

    #expect(entry.relativePath == "bin/wallet-node")
    #expect(entry.identifier == "ai.ethereum.localwallet.wallet-node")
    #expect(entry.cdHashData == Data([
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
        0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33,
    ]))
    #expect(entry.teamIdentifier == "ABCDEFGHIJ")
}

@Test func trustedHelperManifestRejectsPathOrTeamSubstitution() {
    let data = Data(
        #"{"schemaVersion":1,"helpers":{"wallet-node":{"relativePath":"../../tmp/wallet-node","identifier":"ai.ethereum.localwallet.wallet-node","cdHash":"00112233445566778899aabbccddeeff00112233","teamIdentifier":"ATTACKER01"}}}"#.utf8
    )

    #expect(throws: TrustedHelperTrustError.self) {
        _ = try TrustedHelperExecutableResolver.manifestEntry(
            for: .walletNode,
            data: data,
            outerAppTeamIdentifier: "ABCDEFGHIJ"
        )
    }
}

@Test func launchGateNeverDeliversASecretWhenAuthenticationFails() {
    enum InjectedFailure: Error { case rejected }
    let recorder = TrustedHelperGateRecorder()
    let executable = TrustedHelperExecutable.testFixture

    #expect(throws: InjectedFailure.self) {
        try TrustedHelperLaunchGate.authenticateDeliverAndResume(
            pid: 771,
            executable: executable,
            deliverSecret: { recorder.record("secret") },
            operations: .init(
                authenticate: { _, _ in
                    recorder.record("authenticate")
                    throw InjectedFailure.rejected
                },
                resume: { _ in recorder.record("resume") },
                abortAndReap: { _ in recorder.record("abort") }
            )
        )
    }

    #expect(recorder.events == ["authenticate", "abort"])
}

@Test func launchGateAuthenticatesBeforeSecretDeliveryAndResume() throws {
    let recorder = TrustedHelperGateRecorder()

    try TrustedHelperLaunchGate.authenticateDeliverAndResume(
        pid: 772,
        executable: .testFixture,
        deliverSecret: { recorder.record("secret") },
        operations: .init(
            authenticate: { _, _ in recorder.record("authenticate") },
            resume: { _ in recorder.record("resume") },
            abortAndReap: { _ in recorder.record("abort") }
        )
    )

    #expect(recorder.events == ["authenticate", "secret", "resume"])
}

#if DEBUG
@Test func suspendedInRepoHelperMatchesItsCapturedDebugIdentity() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        repoRoot.appendingPathComponent("local-wallet-daemon/target/debug/wallet-node"),
        repoRoot.appendingPathComponent("local-wallet-daemon/target/release/wallet-node"),
    ]
    guard let helperURL = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        return
    }

    let executable = try TrustedHelperExecutableResolver.resolve(
        .walletNode,
        environment: ["LOCAL_WALLET_NODE_BIN": helperURL.path],
        mode: .debug,
        bundleResourceURL: nil,
        sourceRootURL: repoRoot
    )
    var readyPipe: [Int32] = [-1, -1]
    var alivePipe: [Int32] = [-1, -1]
    var secretPipe: [Int32] = [-1, -1]
    #expect(pipe(&readyPipe) == 0)
    #expect(pipe(&alivePipe) == 0)
    #expect(pipe(&secretPipe) == 0)

    var pid: pid_t = -1
    defer {
        for fd in readyPipe + alivePipe + secretPipe where fd >= 0 { _ = Darwin.close(fd) }
        if pid > 0 {
            _ = Darwin.kill(pid, SIGKILL)
            var status: Int32 = 0
            while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
        }
    }

    pid = try spawnHelper(
        execPath: executable.path,
        readyWrite: readyPipe[1],
        aliveRead: alivePipe[0],
        secretRead: secretPipe[0],
        startSuspended: true
    )
    try TrustedHelperProcessValidator.validate(pid: pid, expected: executable.expectation)
}
#endif

@Test func processValidatorRejectsEveryPinnedIdentityMismatch() {
    let expected = TrustedHelperExpectation(
        canonicalPath: "/Applications/Local Wallet.app/Contents/Resources/bin/wallet-node",
        identifier: "ai.ethereum.localwallet.wallet-node",
        teamIdentifier: "ABCDEFGHIJ",
        cdHash: Data(repeating: 0x11, count: 20),
        requiresTrustedSigner: true,
        requiresHardenedRuntime: true
    )
    let valid = TrustedHelperCodeIdentity(
        canonicalPath: expected.canonicalPath,
        identifier: expected.identifier,
        teamIdentifier: expected.teamIdentifier,
        cdHash: expected.cdHash,
        signatureFlags: [.runtime]
    )

    #expect(throws: TrustedHelperTrustError.self) {
        try TrustedHelperProcessValidator.validate(
            identity: replacing(valid, path: "/tmp/wallet-node"),
            expected: expected
        )
    }
    #expect(throws: TrustedHelperTrustError.self) {
        try TrustedHelperProcessValidator.validate(
            identity: replacing(valid, identifier: "ai.attacker.wallet-node"),
            expected: expected
        )
    }
    #expect(throws: TrustedHelperTrustError.self) {
        try TrustedHelperProcessValidator.validate(
            identity: replacing(valid, team: "ATTACKER01"),
            expected: expected
        )
    }
    #expect(throws: TrustedHelperTrustError.self) {
        try TrustedHelperProcessValidator.validate(
            identity: replacing(valid, cdHash: Data(repeating: 0x22, count: 20)),
            expected: expected
        )
    }
    #expect(throws: TrustedHelperTrustError.self) {
        try TrustedHelperProcessValidator.validate(
            identity: replacing(valid, flags: [.adhoc, .runtime]),
            expected: expected
        )
    }
    #expect(throws: TrustedHelperTrustError.self) {
        try TrustedHelperProcessValidator.validate(
            identity: replacing(valid, flags: []),
            expected: expected
        )
    }
}

@Test func outerManifestSealMustBelongToTheRunningAppIdentity() throws {
    let running = TrustedHelperCodeIdentity(
        canonicalPath: "/Applications/Local Wallet.app",
        identifier: "ai.ethereum.localwallet.demo",
        teamIdentifier: "ABCDEFGHIJ",
        cdHash: Data(repeating: 0x33, count: 20),
        signatureFlags: [.runtime]
    )

    try TrustedHelperCodeIdentity.validateOuterIdentityLink(
        runningIdentity: running,
        staticIdentity: running
    )

    let substitutions = [
        replacing(running, path: "/Applications/Substituted.app"),
        replacing(running, identifier: "ai.attacker.wallet"),
        replacing(running, team: "ATTACKER01"),
        replacing(running, cdHash: Data(repeating: 0x44, count: 20)),
        replacing(running, flags: [.adhoc, .runtime]),
        replacing(running, flags: []),
    ]
    for substituted in substitutions {
        #expect(throws: TrustedHelperTrustError.self) {
            try TrustedHelperCodeIdentity.validateOuterIdentityLink(
                runningIdentity: running,
                staticIdentity: substituted
            )
        }
    }
}

private final class TrustedHelperGateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private extension TrustedHelperExecutable {
    static let testFixture = TrustedHelperExecutable(
        kind: .walletNode,
        path: "/tmp/wallet-node",
        expectation: TrustedHelperExpectation(
            canonicalPath: "/tmp/wallet-node",
            identifier: "ai.ethereum.localwallet.wallet-node",
            teamIdentifier: nil,
            cdHash: Data(repeating: 0x42, count: 20),
            requiresTrustedSigner: false,
            requiresHardenedRuntime: false
        )
    )
}

private func replacing(
    _ identity: TrustedHelperCodeIdentity,
    path: String? = nil,
    identifier: String? = nil,
    team: String? = nil,
    cdHash: Data? = nil,
    flags: SecCodeSignatureFlags? = nil
) -> TrustedHelperCodeIdentity {
    TrustedHelperCodeIdentity(
        canonicalPath: path ?? identity.canonicalPath,
        identifier: identifier ?? identity.identifier,
        teamIdentifier: team ?? identity.teamIdentifier,
        cdHash: cdHash ?? identity.cdHash,
        signatureFlags: flags ?? identity.signatureFlags
    )
}
