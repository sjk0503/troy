import Foundation
import Testing
@testable import TroyCore

/// A database file in a unique temporary folder that disappears with the value.
final class TempDir: @unchecked Sendable {
    let folder: URL
    var file: String { folder.appendingPathComponent("troy.db").path }

    init() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("troy-tests-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func store(_ agent: String = "tester/1", searchIndex: Bool = true) throws -> Store {
        try Store(path: file, agent: agent, searchIndex: searchIndex)
    }
}

extension TroyError {
    var isNotFound: Bool { if case .notFound = self { true } else { false } }
    var isInvalid: Bool { if case .invalid = self { true } else { false } }
    var isConflict: Bool { if case .conflict = self { true } else { false } }
    var isDatabase: Bool { if case .database = self { true } else { false } }
}

/// Runs `body` and returns the `TroyError` it threw, or nil.
func thrown(_ body: () throws -> Void) -> TroyError? {
    do {
        try body()
        return nil
    } catch let error as TroyError {
        return error
    } catch {
        return .database("\(error)")
    }
}

extension Store {
    /// Runs SQL straight on the connection (tests only).
    func sql(_ statement: String) throws {
        try read { try $0.execute(statement) }
    }

    func count(_ statement: String) throws -> Int {
        try read { Int(try $0.int(statement) ?? 0) }
    }

    @discardableResult
    func makeProject(_ name: String = "demo", paths: [String] = []) throws -> Project {
        try createProject(name: name, paths: paths)
    }

    @discardableResult
    func add(
        _ project: Project, _ title: String, kind: RecordKind = .task, status: RecordStatus = .open, body: String = "",
        tags: [String] = [], paths: [String] = [], parent: Int64? = nil, links: [LinkDraft] = []
    ) throws -> Record {
        try create(RecordDraft(
            projectID: project.id, kind: kind, title: title, body: body, tags: tags, paths: paths,
            status: status, parent: parent, links: links
        )).record
    }
}
