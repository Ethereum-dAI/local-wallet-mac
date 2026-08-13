import Foundation
import Testing

@Suite struct ProductCopyPunctuationAuditTests {
    @Test func runtimeAppSourceContainsNoEmDash() throws {
        let forbidden = String(UnicodeScalar(0x2014)!)
        let root = packageRoot()
            .appendingPathComponent("Sources/WalletMacOSApp", isDirectory: true)
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        var offenders: [String] = []

        for relativePath in files {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            var inBlockComment = false
            for (offset, line) in source.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if inBlockComment {
                    if trimmed.contains("*/") {
                        inBlockComment = false
                    }
                    continue
                }
                if trimmed.hasPrefix("/*") {
                    if !trimmed.contains("*/") {
                        inBlockComment = true
                    }
                    continue
                }
                if trimmed.hasPrefix("//") {
                    continue
                }
                if line.contains(forbidden) {
                    offenders.append("\(relativePath):\(offset + 1): \(line)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            Comment(rawValue: offenders.joined(separator: "\n"))
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
