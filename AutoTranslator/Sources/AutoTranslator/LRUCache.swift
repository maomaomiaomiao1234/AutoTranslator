import Foundation

/// 线程安全 LRU 缓存：字典 + 双向链表，`value`/`setValue` 均为 O(1)。
/// 此前用数组维护访问顺序，每次命中都要对全部 key 做线性查找——翻译缓存的
/// key 携带完整原文，容量 200 时等于每次查缓存做上百次长字符串比较。
/// 可选地按「成本」（如字节数）设置总量上限，用于约束大对象（音频块）缓存的内存占用。
final class LRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private let capacity: Int
    private let totalCostLimit: Int?
    private var nodes: [Key: Node] = [:]
    private var head: Node? // 最久未使用
    private var tail: Node? // 最近使用
    private var totalCost = 0
    private let lock = NSLock()

    init(capacity: Int, totalCostLimit: Int? = nil) {
        self.capacity = max(1, capacity)
        self.totalCostLimit = totalCostLimit
    }

    deinit {
        // prev/next 双向强引用成环，交给 ARC 会整链泄漏，须手动拆链。
        breakAllLinks()
    }

    func value(forKey key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[key] else { return nil }
        moveToTail(node)
        return node.value
    }

    func setValue(_ value: Value, forKey key: Key, cost: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        if let node = nodes[key] {
            totalCost += cost - node.cost
            node.value = value
            node.cost = cost
            moveToTail(node)
        } else {
            let node = Node(key: key, value: value, cost: cost)
            nodes[key] = node
            appendToTail(node)
            totalCost += cost
        }
        while let victim = head,
              nodes.count > capacity
                || (totalCostLimit.map { totalCost > $0 && nodes.count > 1 } ?? false) {
            unlink(victim)
            nodes.removeValue(forKey: victim.key)
            totalCost -= victim.cost
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        breakAllLinks()
        nodes.removeAll()
        totalCost = 0
        head = nil
        tail = nil
    }

    // MARK: - 链表操作（调用方须持有 lock）

    private func appendToTail(_ node: Node) {
        node.prev = tail
        node.next = nil
        tail?.next = node
        tail = node
        if head == nil {
            head = node
        }
    }

    private func unlink(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node {
            head = node.next
        }
        if tail === node {
            tail = node.prev
        }
        node.prev = nil
        node.next = nil
    }

    private func moveToTail(_ node: Node) {
        guard tail !== node else { return }
        unlink(node)
        appendToTail(node)
    }

    private func breakAllLinks() {
        var current = head
        while let node = current {
            current = node.next
            node.prev = nil
            node.next = nil
        }
    }
}
