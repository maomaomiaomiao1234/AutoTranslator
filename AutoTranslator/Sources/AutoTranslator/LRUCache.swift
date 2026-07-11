import Foundation

/// 简单的线程安全 LRU 缓存。容量很小（数十条），故用数组维护访问顺序即可。
/// 可选地按「成本」（如字节数）设置总量上限，用于约束大对象（音频块）缓存的内存占用。
final class LRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private let totalCostLimit: Int?
    private var store: [Key: Value] = [:]
    private var costs: [Key: Int] = [:]
    private var totalCost = 0
    private var order: [Key] = [] // 末尾为最近使用
    private let lock = NSLock()

    init(capacity: Int, totalCostLimit: Int? = nil) {
        self.capacity = max(1, capacity)
        self.totalCostLimit = totalCostLimit
    }

    func value(forKey key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = store[key] else { return nil }
        touch(key)
        return value
    }

    func setValue(_ value: Value, forKey key: Key, cost: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        if let oldCost = costs[key] {
            totalCost -= oldCost
        }
        store[key] = value
        costs[key] = cost
        totalCost += cost
        touch(key)
        while order.count > capacity
                || (totalCostLimit.map { totalCost > $0 && order.count > 1 } ?? false) {
            let evicted = order.removeFirst()
            store.removeValue(forKey: evicted)
            totalCost -= costs.removeValue(forKey: evicted) ?? 0
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
        costs.removeAll()
        totalCost = 0
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
