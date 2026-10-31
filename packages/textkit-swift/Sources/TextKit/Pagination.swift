import Foundation

/// Every item of a list, fetching the next page only when iteration reaches it.
///
/// ```swift
/// for try await message in client.messages.listAll() { ... }
/// ```
public struct AutoPager<Item: Decodable & Sendable>: AsyncSequence, Sendable {
    public typealias Element = Item
    let fetch: @Sendable (_ cursor: String?) async throws -> Page<Item>

    public func makeAsyncIterator() -> Iterator { Iterator(fetch: fetch) }

    public struct Iterator: AsyncIteratorProtocol {
        let fetch: @Sendable (String?) async throws -> Page<Item>
        var buffer: [Item] = []
        var index = 0
        var cursor: String?
        var started = false
        var done = false

        public mutating func next() async throws -> Item? {
            while true {
                if index < buffer.count {
                    defer { index += 1 }
                    return buffer[index]
                }
                if done { return nil }
                if started && cursor == nil { return nil }
                let page = try await fetch(cursor)
                started = true
                buffer = page.data
                index = 0
                if page.hasMore, let next = page.nextCursor, !next.isEmpty {
                    cursor = next
                } else {
                    done = true
                }
            }
        }
    }

    /// Collect every item into an array (fetches every page).
    public func collect() async throws -> [Item] {
        var out: [Item] = []
        for try await item in self { out.append(item) }
        return out
    }
}
