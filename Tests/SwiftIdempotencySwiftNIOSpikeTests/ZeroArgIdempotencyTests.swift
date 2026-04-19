import Testing
@testable import SwiftIdempotencySwiftNIOSpike
import SwiftIdempotency

// Cross-framework confirmation that `@IdempotencyTests` + the
// effect-aware expansion from finding #5 produce warning-clean auto-
// tests alongside NIO deps in an adopter project.

@Suite
@IdempotencyTests
struct SwiftNIOSpikeHealthChecks {

    @Idempotent
    func bootstrapVersion() -> String { "nio-spike-v1" }

    @Idempotent
    func defaultPort() -> Int { 8080 }

    /// Unmarked — should NOT appear in the generated tests.
    func forbiddenHelper() -> Bool { false }
}
