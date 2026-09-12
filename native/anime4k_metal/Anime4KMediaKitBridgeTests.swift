import Foundation

@main
struct Anime4KMediaKitBridgeTests {
    static func main() {
        testPublicationLedgerBoundsEndToEndOwnershipPerPlayer()
        print("Anime4KMediaKitBridgeTests: PASS")
    }

    private static func testPublicationLedgerBoundsEndToEndOwnershipPerPlayer() {
        var ledger = Anime4KMetalPublicationLedger(capacity: 2)
        let firstPlayer: UInt = 101
        let secondPlayer: UInt = 202

        precondition(ledger.reserve(for: firstPlayer))
        precondition(ledger.reserve(for: firstPlayer))
        precondition(
            !ledger.reserve(for: firstPlayer),
            "a player must bypass instead of growing beyond its publication capacity"
        )
        precondition(ledger.inflightCount(for: firstPlayer) == 2)

        // Capacity is per player/runtime handle. One saturated player must not
        // disable Anime4K for another independent player.
        precondition(ledger.reserve(for: secondPlayer))
        precondition(ledger.inflightCount(for: secondPlayer) == 1)

        ledger.release(for: firstPlayer)
        precondition(ledger.inflightCount(for: firstPlayer) == 1)
        precondition(ledger.reserve(for: firstPlayer))
        precondition(ledger.inflightCount(for: firstPlayer) == 2)

        ledger.release(for: firstPlayer)
        ledger.release(for: firstPlayer)
        ledger.release(for: firstPlayer)
        precondition(
            ledger.inflightCount(for: firstPlayer) == 0,
            "duplicate/stale publication completion must never underflow"
        )

        ledger.release(for: secondPlayer)
        precondition(ledger.inflightCount(for: secondPlayer) == 0)
    }
}
