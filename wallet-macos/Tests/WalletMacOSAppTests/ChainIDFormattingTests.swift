import Foundation
import Testing
@testable import WalletMacOSApp

/// A chain ID is an identifier, not a quantity. Interpolating one straight into
/// a SwiftUI `Text` formats it for the viewer's locale, which showed Sepolia as
/// "Chain 11.155.111" in European locales.
@Test func chainIDsRenderWithoutLocaleGrouping() {
    #expect(ChainIDFormatting.text(11_155_111) == "11155111")
    #expect(ChainIDFormatting.text(1) == "1")
}
