import Foundation

/// A value behind a lock. Stands in for `OSAllocatedUnfairLock` (Apple-only)
/// and `Mutex` (needs macOS 15) — NSLock exists on every Foundation.
public final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
