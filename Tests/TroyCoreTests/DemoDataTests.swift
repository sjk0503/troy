import Foundation
import Testing
@testable import TroyCore

@Suite struct DemoDataTests {
    @Test(arguments: [DemoData.Language.english, .korean])
    func seedsEveryFeatureOnceAndIsRepeatable(language: DemoData.Language) throws {
        let store = try Store(path: ":memory:", agent: "app")
        let project = try DemoData.seed(into: store, language: language)
        let again = try DemoData.seed(into: store, language: language)
        #expect(again.id == project.id)
        #expect(store.agent == "app")

        let overview = try store.overview(projectID: project.id)
        #expect(overview.stats.records == 19)
        #expect(overview.doing.count == 2)
        #expect(!overview.ready.isEmpty)
        #expect(!overview.blocked.isEmpty)
        #expect(overview.collisions.contains { $0.kind == .conflict })
        #expect(overview.collisions.contains { $0.kind == .pathOverlap })
        #expect(overview.decisions.allSatisfy { !$0.isSuperseded })

        let graph = try store.graph(projectID: project.id)
        #expect(graph.records.count == 19)
        #expect(Set(graph.links.map(\.relation)) == Set(Relation.allCases))
    }
}
