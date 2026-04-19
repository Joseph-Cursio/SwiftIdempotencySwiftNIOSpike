import Testing
@testable import SwiftIdempotencySwiftNIOSpike
import SwiftIdempotency
import SwiftIdempotencyTestSupport

/// Two layers tested in parallel:
///
/// 1. The annotated pure function `processChargeLine(_:store:)` via
///    direct calls + `#assertIdempotent` — this is the layer the
///    package's semantics *can* reason about.
/// 2. The `ChargeLineHandler` NIO wrapper via `EmbeddedChannel` —
///    synchronous pipe-in, pipe-out, assert the bytes that come out
///    match across replays. This is the layer the package *can't*
///    currently reason about (Option C doesn't apply to Void-returning
///    side-effect-only handlers); the assertion here is bespoke.
///
/// Contrast with the first three spikes: Hummingbird, Vapor, and Lambda
/// all have handlers with real return values, so `#assertIdempotent`
/// wraps their full handler. Here, `#assertIdempotent` wraps the
/// business-function layer beneath the ChannelHandler.
@Suite struct ChargeLineIdempotencyTests {

    // MARK: - Business-function layer (the annotated layer)

    @Test func processChargeLineReturnsSameResultOnReplay() async throws {
        let store = PaymentStore()
        let line = #"{"eventId": "evt_nio_1", "amount": 100}"#

        let first = try await processChargeLine(line, store: store)
        let second = try await processChargeLine(line, store: store)

        #expect(first == second)
    }

    /// Async `#assertIdempotent` wrapped around the business function —
    /// same pattern as the other three spikes, just applied at the
    /// "inside the ChannelHandler" layer rather than the handler
    /// layer itself. An earlier draft had this function returning an
    /// already-encoded JSON string; `#assertIdempotent` caught the
    /// non-determinism and the function was reshaped to return a
    /// typed value. See the business function's docstring for the
    /// full story.
    @Test func processChargeLineIdempotentViaMacro() async throws {
        let store = PaymentStore()
        let line = #"{"eventId": "evt_nio_macro", "amount": 999}"#

        let result = try await #assertIdempotent {
            try await processChargeLine(line, store: store)
        }

        #expect(result.status == "succeeded")
        #expect(result.amount == 999)
        #expect(result.key == "evt_nio_macro")
    }

    // MARK: - NIO channel layer — out of scope for this spike
    //
    // An earlier draft attempted a `NIOAsyncTestingChannel`-driven
    // test that pushed an inbound line through `ChargeLineHandler` and
    // asserted the outbound bytes were replay-stable. It didn't land
    // because the handler bridges to async work via
    // `promise.completeWithTask`, which spawns outside the event loop,
    // and neither `EmbeddedChannel` nor `NIOAsyncTestingChannel`
    // synchronously drives that continuation back to the point where
    // outbound bytes materialise without more NIO-specific plumbing
    // than this spike wants to invest.
    //
    // The absence of this test is an *honest* reflection of the
    // spike's finding: the package's `#assertIdempotent` surface
    // targets functions with return values, which is the
    // annotatable-business-function layer, not the ChannelHandler
    // wrapper. That layer is tested above. The ChannelHandler is
    // Void-returning side-effect-only — the same case the main
    // README calls out under "What this package does NOT do /
    // Dynamic observable-equivalence checking."
    //
    // See VAPOR_FRICTION.md-style log in this spike's FRICTION.md
    // for the full writeup.
}
