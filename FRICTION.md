# SwiftIdempotency × SwiftNIO — Friction Log

Fourth and final framework spike. Structurally the most different of
the four — NIO is a low-level async networking library, not a
handler-shaped framework. Channel handlers are classes with methods
like `channelRead(context:data:)` that return Void and "respond" via
side-effect writes into the pipeline. That's a fundamentally different
annotation surface from the three preceding spikes.

## TL;DR

- **All 5 package-side fixes work at the annotatable layer.** The
  pattern this spike settled on — extract per-frame business logic
  into a pure async function with a real return value, keep the
  ChannelHandler as a thin wrapper — makes the rest of SwiftIdempotency
  fit cleanly. The annotation surface lives on the business function,
  not on the channel handler.
- **Real finding from the `#assertIdempotent` test at the business
  layer:** the first draft of `processChargeLine` returned an
  already-encoded JSON string, and the macro *caught* that it wasn't
  idempotent — same JSON key-ordering non-determinism as Hummingbird's
  finding #4, now proven to hit at the business-function layer too,
  not just HTTP responses. Fix was to return the typed `ChargeResult`
  and let the NIO wrapper encode. Described below as "finding N1."
- **The ChannelHandler layer is out of scope.** The package's current
  semantics (Option C: compare return values) doesn't apply to
  Void-returning side-effect-only handlers. An attempt to test
  `ChargeLineHandler` via `EmbeddedChannel` and then
  `NIOAsyncTestingChannel` didn't land — the handler bridges to async
  work and neither testing channel synchronously drives the async
  continuation back through to the outbound bytes without more
  NIO-specific plumbing than this spike wants to invest. Documented
  below as "N2" — NIO testing ecosystem friction, not a
  SwiftIdempotency concern.
- **Linter loop validates identically** — 3/3 planted negatives fire;
  same `"\(Date.now)"` bypass (L1 from Hummingbird) unchanged.
- **Stability: 10/10 runs green** at the business-function layer.

## N1. `#assertIdempotent` caught pre-encoded JSON return values

**Observed.** The first draft of `processChargeLine` was shaped as
"line in, line out" — returning the already-encoded JSON response
string rather than the typed model:

```swift
@Idempotent
func processChargeLine(_ line: String, store: PaymentStore) async throws -> String {
    let command = try decoder.decode(ChargeCommand.self, from: Data(line.utf8))
    let key = IdempotencyKey(fromAuditedString: command.eventId)
    let result = try await processCharge(amount: command.amount, idempotencyKey: key, store: store)
    return String(data: try JSONEncoder().encode(result), encoding: .utf8) ?? ""
}
```

The `#assertIdempotent`-based test failed with:

```
Precondition failed: #assertIdempotent: closure returned different values
on re-invocation — not idempotent
```

Same root cause as Hummingbird's finding #4: `JSONEncoder` key ordering
isn't deterministic across calls. Two semantically-equal responses
diverge on the wire, and the string-level `Equatable` catches it.

**Fix.** Return the typed `ChargeResult` and move encoding to the NIO
wrapper. Architecturally correct (encoding is a wire concern, not a
business concern) and makes the business function's `Equatable` stable.

**Why this matters.** The finding isn't new — it was logged in
Hummingbird's FRICTION.md. But this spike proves the pattern transcends
"HTTP response bodies": the trap fires any time business logic
prematurely encodes to a string-shaped return. The README's "Comparing
structured responses" guidance is the canonical fix: return typed
values, encode at the boundary. This spike tightens the understanding —
the guidance is universal, not HTTP-specific.

## N2. NIO ChannelHandler layer is side-effect-only and out of
package scope

**Observed.** A `ChannelInboundHandler`'s `channelRead(context:data:)`
method returns Void and produces its "output" via
`context.writeAndFlush(...)`. The package's current semantics compare
*return values* — same return value on re-invocation → "idempotent,
probably." Void returns carry no information; the macro cannot reason
about side-effect-only handlers.

An attempt to work around this at the test level — use
`EmbeddedChannel` (or its async sibling `NIOAsyncTestingChannel`) to
drive the handler and compare the resulting outbound bytes — didn't
land because `ChargeLineHandler` bridges from sync NIO context to the
async business function via `promise.completeWithTask`, and neither
testing channel synchronously drives that continuation back. The bytes
never materialise by the time `readOutbound` is called. Making this
work would require either:

- A `runUntilQuiesced`-style API that synchronously drives both the
  event loop *and* awaits any spawned tasks (doesn't exist in the
  testing surface today).
- Rewriting the handler to stay in the `EventLoopFuture` world and
  not cross into `async` (a NIO-style choice, but loses the async-first
  design of everything else in this project).

**Not pursued.** The missing test is bespoke — the package doesn't
promise a tool for the Void-returning side-effect-only case. Finding
#4's "Option A/B observable-equivalence (dependency-injected mocks)"
deferred slice is what would help here; it's in the package README's
deferred list, not on this spike's critical path.

**Implication for SwiftIdempotency.** The pattern the spike settled on
— extract business logic into a pure async function, keep the
ChannelHandler as a wrapper that calls it — is the right structural
advice for NIO adopters who want idempotency enforcement. The README's
Installation-section note for Lambda adopters already recommends
essentially the same split. A symmetric note for NIO adopters could
help, but the advice is general enough ("factor business logic into
returning functions; annotate those") that the existing Lambda
paragraph reasonably covers it.

## Package-side findings carrying over correctly

| Fix                                       | NIO test that exercises it            | Status |
|-------------------------------------------|---------------------------------------|--------|
| Async `#assertIdempotent`                 | `processChargeLineIdempotentViaMacro` | ✓      |
| `@ExternallyIdempotent(by:)` validation   | `processCharge` build-clean w/ real label | ✓  |
| Effect-aware `@IdempotencyTests`          | `SwiftNIOSpikeHealthChecks` auto-pair | ✓      |
| Decode-then-compare canonical form        | N/A — business fn returns typed value  | ✓ (trivially) |
| Tier-layering (`IdempotencyKey` subsumes) | Compile-level property                | ✓      |

All five fixes land. No new package-side findings.

## Linter-integration loop

Positive cases: `processChargeLine`, `processCharge`, `ChargeLineHandler`
— **0 linter findings**.

Negative cases:

| Rule                          | Site in `SpikeNegatives.swift` | Fired? |
|-------------------------------|--------------------------------|--------|
| `MissingIdempotencyKey`       | line 16 — `UUID().uuidString`  | ✓      |
| `MissingIdempotencyKey`       | line 20 — `"\(Date.now)"`      | ✗ (L1 from Hummingbird) |
| `IdempotencyViolation`        | line 32                        | ✓      |
| `NonIdempotentInRetryContext` | line 39                        | ✓      |

Reproduction: `cd ~/xcode_projects/SwiftProjectLint && swift run CLI
<spike>/Sources --categories idempotency`.

## Conclusion

SwiftNIO is the most structurally different of the four frameworks.
All 5 package-side fixes ship as framework-agnostic *at the layer the
package targets* — the business-function layer beneath the channel
handler. The spike's real contribution is proving that the
decode-then-compare guidance is universal, not HTTP-specific: even
NIO-layer "just compare the bytes" tests flap on JSON key ordering.
The ChannelHandler layer itself (Void-returning, side-effect-only)
is correctly called out as out-of-scope in the main README; this
spike reinforces rather than contradicts that boundary.
