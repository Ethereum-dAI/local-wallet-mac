import Foundation
import Testing
import WalletSignature
@testable import WalletMacOSApp

@Test func sessionKeyStoreCreateReadDeleteRoundTripsSilently() throws {
    let store = SessionKeyStore()
    let keyRef = "session-key-tests-\(UUID().uuidString)"
    defer { try? store.delete(keyRef: keyRef) }

    let created = try store.createIfNeeded(keyRef: keyRef)

    #expect(created.keyRef == keyRef)
    #expect(created.secret.count == 32)
    #expect(created.address.count == 20)
    #expect(try WalletSignature.bundlerAddress(fromSecret: created.secret) == created.address)

    let recreated = try store.createIfNeeded(keyRef: keyRef)
    #expect(recreated.secret == created.secret)
    #expect(recreated.address == created.address)

    let reread = try store.read(keyRef: keyRef)
    #expect(reread.secret == created.secret)
    #expect(reread.address == created.address)

    try store.delete(keyRef: keyRef)
    #expect(try store.hasKey(forKeyRef: keyRef) == false)
}
