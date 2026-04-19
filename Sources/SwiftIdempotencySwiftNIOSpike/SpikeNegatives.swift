import Foundation
import SwiftIdempotency

// Same shape as the three preceding spikes — three planted bugs, one
// per idempotency rule. Exists so the linter-loop axis of validation
// mirrors Hummingbird/Vapor/Lambda exactly.

// MARK: - Negative A — MissingIdempotencyKey

@ExternallyIdempotent(by: "token")
func legacyCharge(amount: Int, token: String) async throws -> String {
    "charge:\(amount):\(token)"
}

func callsLegacyChargeWithFreshUUID() async throws -> String {
    try await legacyCharge(amount: 50, token: UUID().uuidString)
}

func callsLegacyChargeWithDateNow() async throws -> String {
    try await legacyCharge(amount: 50, token: "\(Date.now)")
}

// MARK: - Negative B — IdempotencyViolation

@NonIdempotent
func writeAuditRow(_ message: String) async throws {
    _ = message
}

@Idempotent
func reconcileAccount(_ accountId: String) async throws {
    try await writeAuditRow("reconcile:\(accountId)")
}

// MARK: - Negative C — NonIdempotentInRetryContext

/// @lint.context replayable
func retryScopedJob() async throws {
    try await writeAuditRow("retry-loop-body")
}
