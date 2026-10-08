import Foundation
import AutoApproveCore

@MainActor struct ApprovalTests {}
func expect(_ value: Bool, _ message: String = "Expected true") throws { if !value { throw AppError.message(message) } }
func expectEqual<T: Equatable>(_ first: T, _ second: T, _ message: String = "Values differ") throws { try expect(first == second, message) }
@main struct DiscoveryPolicyCheck {
    @MainActor static func main() throws {
        try ApprovalTests().testDiscoveryNeighborHintsAndNearbyOrder()
        print("PASS passive neighbor filtering, wider subnet hints, nearby order and subnet bounds")
    }
}
