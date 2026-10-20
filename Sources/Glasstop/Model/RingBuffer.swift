/// Fixed-capacity history buffer so memory stays flat no matter how long the app runs.
struct RingBuffer<T> {
    let capacity: Int
    private var storage: [T] = []
    private var head = 0       // index of the oldest element once full

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }

    mutating func append(_ value: T) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[head] = value
            head = (head + 1) % capacity
        }
    }

    /// Oldest → newest.
    var values: [T] {
        guard storage.count == capacity, head != 0 else { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }

    var last: T? {
        guard !storage.isEmpty else { return nil }
        return storage.count < capacity ? storage.last : storage[(head - 1 + capacity) % capacity]
    }

    /// A buffer with a new capacity holding the newest values that fit.
    func resized(to newCapacity: Int) -> RingBuffer<T> {
        var copy = RingBuffer(capacity: newCapacity)
        for value in values.suffix(copy.capacity) { copy.append(value) }
        return copy
    }
}
