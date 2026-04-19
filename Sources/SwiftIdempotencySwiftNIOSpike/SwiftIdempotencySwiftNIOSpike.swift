import Foundation
import NIOCore
import SwiftIdempotency

// SwiftNIO is structurally different from the three handler-shaped
// frameworks already spiked. Channel handlers are classes with methods
// like `channelRead(context:data:)` that return Void and "respond" via
// side effects into the pipeline (`context.writeAndFlush(...)`). The
// package's Option C semantics (compare return values) don't apply to
// those methods directly.
//
// The workable pattern — and the one this spike validates — is to
// extract the per-frame business logic into a pure async function that
// has a real return value, annotate that, and keep the ChannelHandler
// as a thin wrapper. The ChannelHandler itself stays unannotated; the
// annotated layer is the "business function" it calls.

public actor PaymentStore {
    private var processed: [String: ChargeResult] = [:]
    public init() {}

    public func recordIfAbsent(
        key: String,
        result: ChargeResult
    ) -> ChargeResult {
        if let existing = processed[key] { return existing }
        processed[key] = result
        return result
    }
}

public struct ChargeResult: Codable, Equatable, Sendable {
    public let status: String
    public let amount: Int
    public let key: String
}

public struct ChargeCommand: Codable, Sendable {
    public let eventId: String
    public let amount: Int
}

/// Per-line handler — the annotatable layer. Parses a JSON charge
/// command, builds an `IdempotencyKey`, forwards to the key-consuming
/// worker, returns the **typed** `ChargeResult`.
///
/// An earlier version of this function returned the already-encoded
/// JSON string directly, which caused `#assertIdempotent` to flag it
/// as non-idempotent — same story as finding #4 from the Hummingbird
/// spike: `JSONEncoder` key ordering isn't deterministic, so two
/// calls with the same input produce semantically-equal but byte-
/// unequal strings. Returning the typed value dodges the problem by
/// putting the canonical `Equatable` on the caller side of the
/// encoding boundary. The NIO wrapper below encodes, which is
/// architecturally correct anyway — encoding is a wire concern, not
/// a business-logic concern.
@Idempotent
func processChargeLine(
    _ line: String,
    store: PaymentStore
) async throws -> ChargeResult {
    let decoder = JSONDecoder()
    let command = try decoder.decode(
        ChargeCommand.self,
        from: Data(line.utf8)
    )
    let key = IdempotencyKey(fromAuditedString: command.eventId)
    return try await processCharge(
        amount: command.amount,
        idempotencyKey: key,
        store: store
    )
}

/// Inner worker — takes the typed `IdempotencyKey` directly. Same
/// split-handler shape that landed out of Hummingbird's finding #2.
@ExternallyIdempotent(by: "idempotencyKey")
func processCharge(
    amount: Int,
    idempotencyKey: IdempotencyKey,
    store: PaymentStore
) async throws -> ChargeResult {
    let result = ChargeResult(
        status: "succeeded",
        amount: amount,
        key: idempotencyKey.rawValue
    )
    return await store.recordIfAbsent(key: idempotencyKey.rawValue, result: result)
}

/// The ChannelHandler wrapper. Side-effect-only by NIO convention —
/// reads ByteBuffers, dispatches each as a line to `processChargeLine`,
/// writes the response back via `context.writeAndFlush`. Intentionally
/// *not* annotated: this is the layer the package's current semantics
/// can't test via `#assertIdempotent` (Void return, no return-value
/// equivalence). Tests use `EmbeddedChannel` to exercise it; the
/// per-line business logic is tested via the annotated pure function
/// above.
public final class ChargeLineHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private let store: PaymentStore

    public init(store: PaymentStore) {
        self.store = store
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        guard let line = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
            return
        }
        let eventLoop = context.eventLoop
        let store = self.store

        // Bridge the async business function into NIO's EventLoop
        // world. The outer handler stays Void-returning; the typed
        // return from `processChargeLine` lives at the boundary
        // between the NIO layer and the annotated business logic.
        // Encoding is a wire concern — the business function returns
        // a typed `ChargeResult`, this layer encodes it.
        let promise = eventLoop.makePromise(of: ChargeResult.self)
        promise.completeWithTask {
            try await processChargeLine(line.trimmingCharacters(in: .newlines), store: store)
        }
        promise.futureResult.whenComplete { result in
            switch result {
            case .success(let chargeResult):
                do {
                    let encoded = try JSONEncoder().encode(chargeResult)
                    var response = context.channel.allocator.buffer(capacity: encoded.count + 1)
                    response.writeBytes(encoded)
                    response.writeString("\n")
                    context.writeAndFlush(self.wrapOutboundOut(response), promise: nil)
                } catch {
                    context.fireErrorCaught(error)
                }
            case .failure(let error):
                context.fireErrorCaught(error)
            }
        }
    }
}
