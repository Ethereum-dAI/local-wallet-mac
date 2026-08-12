import Darwin
import Foundation
import Security

public enum TrustedHelperKind: String, CaseIterable, Sendable {
    case walletNode = "wallet-node"
    case railgunHelper = "railgun-helper"

    var relativePath: String {
        "bin/\(rawValue)"
    }

    var signingIdentifier: String {
        switch self {
        case .walletNode:
            "ai.ethereum.localwallet.wallet-node"
        case .railgunHelper:
            "ai.ethereum.localwallet.railgun-helper"
        }
    }

    #if DEBUG
    var environmentKeys: [String] {
        switch self {
        case .walletNode:
            ["LOCAL_WALLET_NODE_BIN", "WALLET_NODE_BIN"]
        case .railgunHelper:
            ["RAILGUN_HELPER_BIN", "LOCAL_WALLET_PRIVACY_BIN"]
        }
    }

    fileprivate var sourceBuildDirectory: String {
        switch self {
        case .walletNode:
            "local-wallet-daemon"
        case .railgunHelper:
            "local-wallet-railgun"
        }
    }
    #endif
}

public enum TrustedHelperBuildMode: Sendable {
    case debug
    case release

    public static let current: TrustedHelperBuildMode = {
        #if DEBUG
        .debug
        #else
        .release
        #endif
    }()
}

public struct TrustedHelperExpectation: Equatable, Sendable {
    let canonicalPath: String
    let identifier: String
    let teamIdentifier: String?
    let cdHash: Data
    let requiresTrustedSigner: Bool
    let requiresHardenedRuntime: Bool
}

public struct TrustedHelperExecutable: Equatable, Sendable {
    public let kind: TrustedHelperKind
    public let path: String
    let expectation: TrustedHelperExpectation
}

struct TrustedHelperManifestEntry: Equatable, Sendable {
    let relativePath: String
    let identifier: String
    let cdHashData: Data
    let teamIdentifier: String
}

enum TrustedHelperTrustError: LocalizedError, Equatable {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let message):
            "Trusted helper launch rejected: \(message)"
        }
    }
}

public enum TrustedHelperExecutableResolver {
    private static let manifestName = "trusted-helpers.json"

    public static func resolve(
        _ kind: TrustedHelperKind,
        environment: [String: String],
        mode: TrustedHelperBuildMode = .current,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        bundleURL: URL = Bundle.main.bundleURL,
        sourceRootURL: URL = defaultSourceRootURL,
        fileManager: FileManager = .default
    ) throws -> TrustedHelperExecutable {
        switch mode {
        case .release:
            return try resolveRelease(
                kind,
                bundleResourceURL: bundleResourceURL,
                bundleURL: bundleURL,
                fileManager: fileManager
            )
        case .debug:
            #if DEBUG
            return try resolveDebug(
                kind,
                environment: environment,
                bundleResourceURL: bundleResourceURL,
                sourceRootURL: sourceRootURL,
                fileManager: fileManager
            )
            #else
            throw TrustedHelperTrustError.rejected(
                "Debug helper selection is not compiled into Release builds."
            )
            #endif
        }
    }

    static func candidateURLs(
        for kind: TrustedHelperKind,
        environment: [String: String],
        mode: TrustedHelperBuildMode,
        bundleResourceURL: URL?,
        sourceRootURL: URL
    ) -> [URL] {
        let bundledURL = bundleResourceURL?.appendingPathComponent(kind.relativePath)

        switch mode {
        case .release:
            return bundledURL.map { [$0] } ?? []
        case .debug:
            #if DEBUG
            var candidates = kind.environmentKeys.compactMap { key -> URL? in
                guard let path = environment[key], path.isEmpty == false else { return nil }
                return URL(fileURLWithPath: path)
            }
            if let bundledURL {
                candidates.append(bundledURL)
                candidates.append(bundleResourceURL!.appendingPathComponent(kind.rawValue))
            }
            for profile in ["release", "debug"] {
                candidates.append(
                    sourceRootURL
                        .appendingPathComponent(kind.sourceBuildDirectory, isDirectory: true)
                        .appendingPathComponent("target", isDirectory: true)
                        .appendingPathComponent(profile, isDirectory: true)
                        .appendingPathComponent(kind.rawValue)
                )
            }
            return candidates
            #else
            return bundledURL.map { [$0] } ?? []
            #endif
        }
    }

    static func validateBundledExecutableURL(
        for kind: TrustedHelperKind,
        bundleResourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let resources = bundleResourceURL.standardizedFileURL
        let binDirectory = resources.appendingPathComponent("bin", isDirectory: true)
        let expected = resources.appendingPathComponent(kind.relativePath).standardizedFileURL

        try requireFileType(resources, expectedType: S_IFDIR, description: "app Resources directory")
        try requireFileType(binDirectory, expectedType: S_IFDIR, description: "trusted helper bin directory")
        try requireFileType(expected, expectedType: S_IFREG, description: kind.rawValue)
        guard fileManager.isExecutableFile(atPath: expected.path) else {
            throw TrustedHelperTrustError.rejected("\(kind.rawValue) is not executable.")
        }

        let canonicalResources = resources.resolvingSymlinksInPath().standardizedFileURL
        let canonicalBin = binDirectory.resolvingSymlinksInPath().standardizedFileURL
        let canonicalExpected = expected.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalBin == canonicalResources.appendingPathComponent("bin", isDirectory: true),
              canonicalExpected == canonicalBin.appendingPathComponent(kind.rawValue)
        else {
            throw TrustedHelperTrustError.rejected(
                "\(kind.rawValue) escapes its canonical app bundle location."
            )
        }
        return canonicalExpected
    }

    static func manifestEntry(
        for kind: TrustedHelperKind,
        data: Data,
        outerAppTeamIdentifier: String
    ) throws -> TrustedHelperManifestEntry {
        let manifest: TrustedHelperManifest
        do {
            manifest = try JSONDecoder().decode(TrustedHelperManifest.self, from: data)
        } catch {
            throw TrustedHelperTrustError.rejected("trusted helper manifest is invalid JSON.")
        }
        guard manifest.schemaVersion == 1 else {
            throw TrustedHelperTrustError.rejected("trusted helper manifest schema is unsupported.")
        }
        guard let raw = manifest.helpers[kind.rawValue] else {
            throw TrustedHelperTrustError.rejected("trusted helper manifest omits \(kind.rawValue).")
        }
        guard raw.relativePath == kind.relativePath else {
            throw TrustedHelperTrustError.rejected("\(kind.rawValue) manifest path is not canonical.")
        }
        guard raw.identifier == kind.signingIdentifier else {
            throw TrustedHelperTrustError.rejected("\(kind.rawValue) manifest identifier is wrong.")
        }
        guard raw.teamIdentifier == outerAppTeamIdentifier else {
            throw TrustedHelperTrustError.rejected(
                "\(kind.rawValue) is not assigned to the outer app signing team."
            )
        }
        guard let cdHash = Data(strictHex: raw.cdHash), cdHash.count == 20 || cdHash.count == 32 else {
            throw TrustedHelperTrustError.rejected("\(kind.rawValue) manifest CDHash is invalid.")
        }
        return TrustedHelperManifestEntry(
            relativePath: raw.relativePath,
            identifier: raw.identifier,
            cdHashData: cdHash,
            teamIdentifier: raw.teamIdentifier
        )
    }

    private static func resolveRelease(
        _ kind: TrustedHelperKind,
        bundleResourceURL: URL?,
        bundleURL: URL,
        fileManager: FileManager
    ) throws -> TrustedHelperExecutable {
        guard let bundleResourceURL else {
            throw TrustedHelperTrustError.rejected("the app bundle has no Resources directory.")
        }
        let helperURL = try validateBundledExecutableURL(
            for: kind,
            bundleResourceURL: bundleResourceURL,
            fileManager: fileManager
        )
        let manifestURL = bundleResourceURL.appendingPathComponent(manifestName)
        try requireFileType(manifestURL, expectedType: S_IFREG, description: manifestName)
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        } catch {
            throw TrustedHelperTrustError.rejected("the trusted helper manifest could not be read.")
        }

        let appIdentity = try TrustedHelperCodeIdentity.validatedOuterAppIdentity(
            bundleURL: bundleURL,
            manifestData: manifestData,
            manifestRelativePath: "Resources/\(manifestName)"
        )
        guard let appTeam = appIdentity.teamIdentifier else {
            throw TrustedHelperTrustError.rejected("the outer app has no Apple Team ID.")
        }
        let entry = try manifestEntry(
            for: kind,
            data: manifestData,
            outerAppTeamIdentifier: appTeam
        )
        let expectation = TrustedHelperExpectation(
            canonicalPath: helperURL.path,
            identifier: entry.identifier,
            teamIdentifier: entry.teamIdentifier,
            cdHash: entry.cdHashData,
            requiresTrustedSigner: true,
            requiresHardenedRuntime: true
        )
        let identity = try TrustedHelperCodeIdentity.staticIdentity(
            at: helperURL,
            requirement: try TrustedHelperCodeIdentity.requirement(for: expectation)
        )
        try TrustedHelperProcessValidator.validate(identity: identity, expected: expectation)
        return TrustedHelperExecutable(kind: kind, path: helperURL.path, expectation: expectation)
    }

    #if DEBUG
    private static func resolveDebug(
        _ kind: TrustedHelperKind,
        environment: [String: String],
        bundleResourceURL: URL?,
        sourceRootURL: URL,
        fileManager: FileManager
    ) throws -> TrustedHelperExecutable {
        let candidates = candidateURLs(
            for: kind,
            environment: environment,
            mode: .debug,
            bundleResourceURL: bundleResourceURL,
            sourceRootURL: sourceRootURL
        )
        var lastRejection: Error?
        for candidate in candidates where candidate.path.hasPrefix("/") {
            guard fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            do {
                try requireFileType(candidate, expectedType: S_IFREG, description: kind.rawValue)
                let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
                let identity = try TrustedHelperCodeIdentity.staticIdentity(at: canonical)
                let expectation = TrustedHelperExpectation(
                    canonicalPath: identity.canonicalPath,
                    identifier: identity.identifier,
                    teamIdentifier: identity.teamIdentifier,
                    cdHash: identity.cdHash,
                    requiresTrustedSigner: false,
                    requiresHardenedRuntime: false
                )
                return TrustedHelperExecutable(
                    kind: kind,
                    path: canonical.path,
                    expectation: expectation
                )
            } catch {
                lastRejection = error
            }
        }
        if let lastRejection {
            throw lastRejection
        }
        throw TrustedHelperTrustError.rejected(
            "\(kind.rawValue) was not found. Build the in-repo helper or set a Debug-only absolute override."
        )
    }
    #endif

    private static func requireFileType(
        _ url: URL,
        expectedType: mode_t,
        description: String
    ) throws {
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            throw TrustedHelperTrustError.rejected("\(description) is missing.")
        }
        guard (fileStatus.st_mode & S_IFMT) == expectedType else {
            throw TrustedHelperTrustError.rejected(
                "\(description) must be a regular, non-symlink filesystem object."
            )
        }
    }

    public static let defaultSourceRootURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

enum TrustedHelperProcessValidator {
    static func validate(pid: pid_t, expected: TrustedHelperExpectation) throws {
        guard pid > 0 else {
            throw TrustedHelperTrustError.rejected("the spawned helper PID is invalid.")
        }
        let identity = try TrustedHelperCodeIdentity.runningIdentity(
            pid: pid,
            requirement: try TrustedHelperCodeIdentity.requirement(for: expected)
        )
        try validate(identity: identity, expected: expected)
    }

    static func validate(
        identity: TrustedHelperCodeIdentity,
        expected: TrustedHelperExpectation
    ) throws {
        guard identity.canonicalPath == expected.canonicalPath else {
            throw TrustedHelperTrustError.rejected("the running helper path changed before launch.")
        }
        guard identity.identifier == expected.identifier else {
            throw TrustedHelperTrustError.rejected("the running helper signing identifier is wrong.")
        }
        guard identity.teamIdentifier == expected.teamIdentifier else {
            throw TrustedHelperTrustError.rejected("the running helper Team ID is wrong.")
        }
        guard identity.cdHash == expected.cdHash else {
            throw TrustedHelperTrustError.rejected("the running helper CDHash is wrong.")
        }
        if expected.requiresTrustedSigner, identity.signatureFlags.contains(.adhoc) {
            throw TrustedHelperTrustError.rejected("the running helper is ad-hoc signed.")
        }
        if expected.requiresHardenedRuntime, !identity.signatureFlags.contains(.runtime) {
            throw TrustedHelperTrustError.rejected("the running helper lacks hardened runtime.")
        }
    }
}

struct TrustedHelperCodeIdentity: Equatable, Sendable {
    let canonicalPath: String
    let identifier: String
    let teamIdentifier: String?
    let cdHash: Data
    let signatureFlags: SecCodeSignatureFlags

    static func staticIdentity(
        at url: URL,
        requirement: SecRequirement? = nil
    ) throws -> TrustedHelperCodeIdentity {
        var staticCode: SecStaticCode?
        try check(
            SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode),
            operation: "create static code reference"
        )
        guard let staticCode else {
            throw TrustedHelperTrustError.rejected("Security.framework returned no static code.")
        }
        let validationFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSRestrictSymlinks
        )
        try check(
            SecStaticCodeCheckValidity(staticCode, validationFlags, requirement),
            operation: "validate helper signature"
        )
        return try identity(from: staticCode)
    }

    static func runningIdentity(
        pid: pid_t,
        requirement: SecRequirement
    ) throws -> TrustedHelperCodeIdentity {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: pid),
        ] as CFDictionary
        var dynamicCode: SecCode?
        try check(
            SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &dynamicCode),
            operation: "resolve spawned helper code"
        )
        guard let dynamicCode else {
            throw TrustedHelperTrustError.rejected("Security.framework returned no running code.")
        }
        try check(
            SecCodeCheckValidity(dynamicCode, SecCSFlags(), requirement),
            operation: "authenticate spawned helper"
        )

        // These C APIs explicitly accept a dynamic SecCode, but Swift imports their parameter
        // as SecStaticCode. Preserve the dynamic object so the identity is tied to this PID.
        let signingInformationView = unsafeBitCast(dynamicCode, to: SecStaticCode.self)
        return try identity(from: signingInformationView)
    }

    static func requirement(for expected: TrustedHelperExpectation) throws -> SecRequirement {
        var clauses = [
            #"identifier "\#(requirementEscaped(expected.identifier))""#,
            #"cdhash H"\#(expected.cdHash.trustedHelperHexString)""#,
        ]
        if expected.requiresTrustedSigner {
            guard let teamIdentifier = expected.teamIdentifier else {
                throw TrustedHelperTrustError.rejected("a trusted helper expectation has no Team ID.")
            }
            clauses.append("anchor apple generic")
            clauses.append(
                #"certificate leaf[subject.OU] = "\#(requirementEscaped(teamIdentifier))""#
            )
        }
        var requirement: SecRequirement?
        try check(
            SecRequirementCreateWithString(
                clauses.joined(separator: " and ") as CFString,
                SecCSFlags(),
                &requirement
            ),
            operation: "create helper code requirement"
        )
        guard let requirement else {
            throw TrustedHelperTrustError.rejected("Security.framework returned no code requirement.")
        }
        return requirement
    }

    static func validatedOuterAppIdentity(
        bundleURL: URL,
        manifestData: Data,
        manifestRelativePath: String
    ) throws -> TrustedHelperCodeIdentity {
        var selfCode: SecCode?
        try check(SecCodeCopySelf(SecCSFlags(), &selfCode), operation: "resolve outer app code")
        guard let selfCode else {
            throw TrustedHelperTrustError.rejected("Security.framework returned no outer app code.")
        }
        try check(
            SecCodeCheckValidity(selfCode, SecCSFlags(), nil),
            operation: "validate running outer app"
        )
        let dynamicView = unsafeBitCast(selfCode, to: SecStaticCode.self)
        let runningIdentity = try identity(from: dynamicView)
        let expectedBundlePath = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard runningIdentity.canonicalPath == expectedBundlePath else {
            throw TrustedHelperTrustError.rejected("the running code is not the expected app bundle.")
        }
        guard runningIdentity.teamIdentifier != nil,
              !runningIdentity.signatureFlags.contains(.adhoc),
              runningIdentity.signatureFlags.contains(.runtime)
        else {
            throw TrustedHelperTrustError.rejected(
                "the outer app requires an identified hardened-runtime signature."
            )
        }

        var staticApp: SecStaticCode?
        try check(
            SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticApp),
            operation: "resolve outer app bundle"
        )
        guard let staticApp else {
            throw TrustedHelperTrustError.rejected("Security.framework returned no app bundle code.")
        }
        let validationFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSRestrictSymlinks
        )
        try check(
            SecStaticCodeCheckValidity(staticApp, validationFlags, nil),
            operation: "validate outer app bundle seal"
        )
        let staticIdentity = try identity(from: staticApp)
        try validateOuterIdentityLink(
            runningIdentity: runningIdentity,
            staticIdentity: staticIdentity
        )
        try check(
            SecCodeValidateFileResource(
                staticApp,
                manifestRelativePath as CFString,
                manifestData as CFData,
                SecCSFlags()
            ),
            operation: "validate trusted helper manifest seal"
        )
        return runningIdentity
    }

    static func validateOuterIdentityLink(
        runningIdentity: TrustedHelperCodeIdentity,
        staticIdentity: TrustedHelperCodeIdentity
    ) throws {
        guard staticIdentity.canonicalPath == runningIdentity.canonicalPath,
              staticIdentity.identifier == runningIdentity.identifier,
              staticIdentity.teamIdentifier == runningIdentity.teamIdentifier,
              staticIdentity.cdHash == runningIdentity.cdHash,
              staticIdentity.signatureFlags.contains(.adhoc)
                == runningIdentity.signatureFlags.contains(.adhoc),
              staticIdentity.signatureFlags.contains(.runtime)
                == runningIdentity.signatureFlags.contains(.runtime)
        else {
            throw TrustedHelperTrustError.rejected(
                "the on-disk app bundle does not match the running app identity."
            )
        }
    }

    private static func identity(from code: SecStaticCode) throws -> TrustedHelperCodeIdentity {
        var information: CFDictionary?
        try check(
            SecCodeCopySigningInformation(
                code,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
            ),
            operation: "read code signing information"
        )
        guard let dictionary = information as? [String: Any],
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
              let cdHash = dictionary[kSecCodeInfoUnique as String] as? Data,
              let rawFlags = dictionary[kSecCodeInfoFlags as String] as? NSNumber
        else {
            throw TrustedHelperTrustError.rejected("code signing identity is incomplete.")
        }
        var path: CFURL?
        try check(
            SecCodeCopyPath(code, SecCSFlags(), &path),
            operation: "read signed code path"
        )
        guard let url = path as URL? else {
            throw TrustedHelperTrustError.rejected("signed code has no canonical path.")
        }
        return TrustedHelperCodeIdentity(
            canonicalPath: url.resolvingSymlinksInPath().standardizedFileURL.path,
            identifier: identifier,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            cdHash: cdHash,
            signatureFlags: SecCodeSignatureFlags(rawValue: rawFlags.uint32Value)
        )
    }

    private static func requirementEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw TrustedHelperTrustError.rejected("\(operation) failed: \(detail).")
        }
    }
}

public enum TrustedHelperLaunchGate {
    public struct Operations: Sendable {
        let authenticate: @Sendable (pid_t, TrustedHelperExpectation) throws -> Void
        let resume: @Sendable (pid_t) throws -> Void
        let abortAndReap: @Sendable (pid_t) -> Void

        public static let live = Operations(
            authenticate: TrustedHelperProcessValidator.validate,
            resume: { try resumeHelper(pid: $0) },
            abortAndReap: abortSuspendedHelperAndReap
        )
    }

    public static func authenticateDeliverAndResume(
        pid: pid_t,
        executable: TrustedHelperExecutable,
        deliverSecret: () throws -> Void,
        operations: Operations = .live
    ) throws {
        do {
            try operations.authenticate(pid, executable.expectation)
            try deliverSecret()
            try operations.resume(pid)
        } catch {
            operations.abortAndReap(pid)
            throw error
        }
    }

    private static func abortSuspendedHelperAndReap(_ pid: pid_t) {
        guard pid > 0 else { return }
        if Darwin.kill(pid, SIGKILL) != 0, errno != ESRCH {
            return
        }
        var status: Int32 = 0
        while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }
}

private struct TrustedHelperManifest: Decodable {
    struct Entry: Decodable {
        let relativePath: String
        let identifier: String
        let cdHash: String
        let teamIdentifier: String
    }

    let schemaVersion: Int
    let helpers: [String: Entry]
}

private extension Data {
    init?(strictHex string: String) {
        guard string.isEmpty == false, string.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    var trustedHelperHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
