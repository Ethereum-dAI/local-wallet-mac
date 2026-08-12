import Foundation

enum SessionSwapRouterRegistry {
    static func routers(on chainID: UInt64) -> [String] {
        switch chainID {
        case 11_155_111:
            return ["0x3bfa4769fb09eefc5a80d6e87c3b9c650f7ae48e"]
        default:
            return []
        }
    }

    static func routerSet(on chainID: UInt64) -> Set<String> {
        Set(routers(on: chainID).map { $0.lowercased() })
    }
}
