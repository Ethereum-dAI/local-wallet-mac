import SwiftUI

/// Simple slash-command discovery affordance: a menu button beside the
/// composer that inserts a scaffold for /transfer or /swap so users
/// don't have to memorise the grammar. A future iteration may replace
/// this with an inline NSPopover autocomplete.
struct SlashMenuButton: View {
    /// Called with a scaffold string (e.g. /transfer 0.1 ETH to ) that
    /// should be inserted into the composer at the current caret.
    let onInsert: (String) -> Void

    var body: some View {
        Menu {
            Button("/transfer <amount> <token> to <recipient>") {
                onInsert("/transfer 0.1 ETH to ")
            }
            Button("/swap <amount> <from_token> to <to_token>") {
                onInsert("/swap 100 USDC to ETH")
            }
        } label: {
            Image(systemName: "slash.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .help("Insert a slash command")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
