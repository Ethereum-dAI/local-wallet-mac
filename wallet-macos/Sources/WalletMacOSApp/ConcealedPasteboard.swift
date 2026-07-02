import AppKit

// Clipboard hygiene for exported secrets: mark the pasteboard item with the
// de-facto "concealed" type so clipboard managers and Universal Clipboard skip
// it, and clear the pasteboard after a delay unless the user has already
// copied something else over it.
@MainActor
enum ConcealedPasteboard {
    nonisolated static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    nonisolated static let defaultClearDelay: TimeInterval = 60

    @discardableResult
    static func copy(
        _ secret: String,
        to pasteboard: NSPasteboard = .general,
        clearAfter delay: TimeInterval? = defaultClearDelay
    ) -> Int {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedType], owner: nil)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setString(secret, forType: concealedType)

        let changeCount = pasteboard.changeCount
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                clearIfUnchanged(pasteboard: pasteboard, expectedChangeCount: changeCount)
            }
        }
        return changeCount
    }

    static func clearIfUnchanged(pasteboard: NSPasteboard = .general, expectedChangeCount: Int) {
        guard pasteboard.changeCount == expectedChangeCount else {
            return
        }
        pasteboard.clearContents()
    }
}
