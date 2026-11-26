import Foundation
import TroyCore

/// Runs database work off the main thread. The app owns one client; every view model call goes through it.
nonisolated public final class StoreClient: Sendable {
    public let path: String
    private let store: Store
    private let queue = DispatchQueue(label: "dev.troy.app.store", qos: .userInitiated)

    /// Opens (and creates when missing) the database at `path`.
    public init(path: String = Store.defaultPath(), agent: String = "app") throws {
        self.path = path
        self.store = try Store(path: path, agent: agent)
    }

    /// Runs `work` on the store's serial queue and returns its result. Calls finish in the order they were made.
    public func run<T: Sendable>(_ work: @escaping @Sendable (Store) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [store] in
                continuation.resume(with: Result { try work(store) })
            }
        }
    }
}

/// Where the graph screen remembers node positions, so a project's graph looks the same every time it opens.
/// Positions are view state, not data: they live in a JSON file next to the database, never in it.
nonisolated public struct GraphLayoutCache: Sendable {
    private let folder: URL

    public init(databasePath: String) {
        folder = URL(fileURLWithPath: databasePath).deletingLastPathComponent().appendingPathComponent("graph-layout", isDirectory: true)
    }

    private func file(_ projectID: Int64?) -> URL {
        folder.appendingPathComponent("project-\(projectID.map(String.init) ?? "all").json")
    }

    public func load(projectID: Int64?) -> [Int64: CGPoint] {
        guard let data = try? Data(contentsOf: file(projectID)),
              let stored = try? JSONDecoder().decode([String: [Double]].self, from: data)
        else { return [:] }
        var positions: [Int64: CGPoint] = [:]
        for (key, value) in stored where value.count == 2 {
            if let id = Int64(key) { positions[id] = CGPoint(x: value[0], y: value[1]) }
        }
        return positions
    }

    public func save(_ positions: [Int64: CGPoint], projectID: Int64?) {
        var stored: [String: [Double]] = [:]
        for (id, point) in positions where point.x.isFinite && point.y.isFinite {
            stored[String(id)] = [Double(point.x), Double(point.y)]
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file(projectID), options: .atomic)
    }
}
