import Darwin
import Foundation
import XCTest

@testable import WalletMacOSApp

/// Launch-only integration smoke test for the privacy-helper sidecar.
///
/// A real `balance()` call triggers the sidecar's Privacy-Pools pool-sync, which
/// fetches the network (ASP/IPFS + logs) through a real Sepolia daemon — too flaky to
/// run here. So this test asserts only the cheap, deterministic parts of the launch
/// contract: the binary spawns, emits `"ready"` on fd-3 (which `launch` waits for and
/// otherwise throws), and the sidecar's Unix socket then accepts a connection. The
/// daemon socket is never contacted because no RPC is issued (the daemon provider is
/// lazy — see privacy-helper/src/daemon-provider.ts). The full launch + `/shield` flow
/// is a MANUAL Xcode + Sepolia gate.
final class PrivacyHelperSidecarTests: XCTestCase {
    func testLaunchEmitsReadyAndSocketAccepts() async throws {
        try XCTSkipUnless(
            PrivacyHelperSidecar.resolveBinaryPath() != nil,
            "privacy-helper binary not built; run `cd privacy-helper && bun run build`"
        )

        // No chain RPC is issued in this launch-only test, so the provider URL is never
        // contacted (the provider is lazy). launch() internally waits for "ready" on
        // fd-3 and throws if it is absent or malformed, so a successful return already
        // asserts the ready handshake.
        let sidecar = try await PrivacyHelperSidecar.launch(
            entropyHex: "0x" + String(repeating: "11", count: 32),
            providerRpcURL: "http://127.0.0.1:1/",
            authToken: "tok"
        )

        // Keep the sidecar alive until the end of the test; deinit closes fd-4 (EOF →
        // the child exits) and unlinks the socket.
        defer { withExtendedLifetime(sidecar) {} }

        // The sidecar must be listening on the socket path it was told to use. We can't
        // read it back (socketPath is private), so we re-derive acceptance by confirming
        // a fresh AF_UNIX connect to the most-recent ph-*.sock under the temp dir.
        let connected = Self.sidecarSocketAcceptsConnection()
        XCTAssertTrue(connected, "privacy-helper sidecar socket did not accept a connection")
    }

    /// Connects to the newest `ph-*.sock` (not `ph-test-daemon-*`) created under the
    /// temp directory — the sidecar's listening socket — to confirm it accepts a
    /// connection. Returns false if no such socket connects.
    private static func sidecarSocketAcceptsConnection() -> Bool {
        let tempDir = NSTemporaryDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tempDir) else {
            return false
        }
        let candidates = entries
            .filter { $0.hasPrefix("ph-") && $0.hasSuffix(".sock") && !$0.hasPrefix("ph-test-daemon-") }
            .map { tempDir + $0 }
            .sorted { lhs, rhs in
                let l = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? nil
                let r = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? nil
                return (l ?? .distantPast) > (r ?? .distantPast)
            }

        for path in candidates where connectsToUnixSocket(at: path) {
            return true
        }
        return false
    }

    private static func connectsToUnixSocket(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let encoded = Array(path.utf8)
        guard encoded.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            if let base = buffer.baseAddress {
                base.initializeMemory(as: UInt8.self, repeating: 0, count: buffer.count)
            }
            buffer.copyBytes(from: encoded)
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + encoded.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, length)
            }
        }
        return result == 0
    }
}
