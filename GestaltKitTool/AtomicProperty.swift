//
//  AtomicProperty.swift
//  GestaltKitTool
//
//

import Foundation

/// Lock-protected atomic property wrapper.
@propertyWrapper
struct Atomic<Value> {
    private var lock = NSLock()
    private var value: Value

    init(wrappedValue: Value) {
        self.value = wrappedValue
    }

    var wrappedValue: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    /// Atomic read-modify-write.
    @discardableResult
    mutating func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    func load() -> Value {
        lock.withLock { value }
    }

    mutating func store(_ newValue: Value) {
        lock.withLock { value = newValue }
    }
}

extension NSLock {
    @inlinable
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
