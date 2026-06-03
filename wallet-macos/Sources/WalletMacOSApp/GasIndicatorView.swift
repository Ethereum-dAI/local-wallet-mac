import SwiftUI

struct GasTierRow: Identifiable {
    let id: String
    let name: String
    let maxFee: String
    let priority: String
}

struct GasBreakdownDisplay {
    let baseFee: String?
    let tiers: [GasTierRow]
    let modeText: String
    let updatedText: String
}

struct GasBreakdownPopover: View {
    let display: GasBreakdownDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Network gas")
                .font(.system(size: 13, weight: .bold))

            if let baseFee = display.baseFee {
                HStack {
                    Text("Base fee")
                    Spacer()
                    Text("\(baseFee) gwei").bold()
                }
                .font(.system(size: 12))
            }

            Divider()

            HStack {
                Text("Tier").bold()
                Spacer()
                Text("Max / Priority").bold()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            ForEach(display.tiers) { tier in
                HStack {
                    Text(tier.name)
                    Spacer()
                    Text("\(tier.maxFee) / \(tier.priority) gwei")
                }
                .font(.system(size: 12))
            }

            Divider()

            Text(display.modeText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(display.updatedText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 260)
    }
}
