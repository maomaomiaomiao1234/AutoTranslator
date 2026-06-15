import Foundation

/// 简单的线程安全 LRU 缓存。容量很小（数十条），故用数组维护访问顺序即可。
final class LRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private var store: [Key: Value] = [:]
    private var order: [Key] = [] // 末尾为最近使用
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func value(forKey key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = store[key] else { return nil }
        touch(key)
        return value
    }

    func setValue(_ value: Value, forKey key: Key) {
        lock.lock()
        defer { lock.unlock() }
        store[key] = value
        touch(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            store.removeValue(forKey: evicted)
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
        order.removeAll()
    }

    /// 将 key 移到最近使用位置（调用方须持有 lock）。
    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }
}
