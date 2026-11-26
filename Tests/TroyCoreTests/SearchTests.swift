import Foundation
import Testing
@testable import TroyCore

@Suite struct SearchTests {
    /// Two stores on one file: one with the trigram index, one that only uses LIKE.
    private struct Rig {
        let dir = TempDir()
        let indexed: Store
        let plain: Store
        let project: Project
        let other: Project

        init() throws {
            indexed = try dir.store("a/1")
            plain = try dir.store("a/1", searchIndex: false)
            project = try indexed.makeProject("main")
            other = try indexed.makeProject("other")
        }

        @discardableResult
        func add(_ title: String, kind: RecordKind = .note, status: RecordStatus = .open, body: String = "", tags: [String] = [], in project: Project? = nil) throws -> Int64 {
            try indexed.add(project ?? self.project, title, kind: kind, status: status, body: body, tags: tags).id
        }

        /// The ids both stores return, asserting they are the same set.
        func ids(_ text: String, project: Project? = nil, kinds: Set<RecordKind> = [], statuses: Set<RecordStatus> = [], tag: String? = nil, limit: Int = 50) throws -> [Int64] {
            let query = SearchQuery(text: text, projectID: project?.id, kinds: kinds, statuses: statuses, tag: tag, limit: limit)
            let withIndex = try indexed.search(query).map(\.id)
            let withoutIndex = try plain.search(query).map(\.id)
            #expect(Set(withIndex) == Set(withoutIndex), "index and LIKE disagree for \"\(text)\"")
            return withIndex
        }
    }

    @Test func indexAvailabilityFollowsTheInitializer() throws {
        let rig = try Rig()
        #expect(rig.indexed.ftsAvailable)
        #expect(!rig.plain.ftsAvailable)
    }

    @Test func koreanTermsOfTwoAndThreeOrMoreCharacters() throws {
        let rig = try Rig()
        let a = try rig.add("토큰별 호출 제한", body: "API 호출 제한 정책을 정한다")
        let b = try rig.add("배포 절차", body: "스테이징에서 먼저 확인한다")
        #expect(try rig.ids("제한") == [a])          // two characters: LIKE path
        #expect(try rig.ids("정책을") == [a])        // three characters: index path
        #expect(try rig.ids("호출") == [a])
        #expect(try rig.ids("스테이징") == [b])
        #expect(try rig.ids("없는말") == [])
        #expect(try rig.ids("제한 정책을") == [a])   // short and long term together
    }

    @Test func aTermInsideACamelCaseIdentifier() throws {
        let rig = try Rig()
        let a = try rig.add("Auth", body: "func fetchUserProfile() async throws")
        try rig.add("Other", body: "nothing here")
        #expect(try rig.ids("UserProf") == [a])
        #expect(try rig.ids("userprofile") == [a])
        #expect(try rig.ids("FETCH") == [a])
        #expect(try rig.ids("Profile") == [a])
    }

    @Test func tagsAreSearched() throws {
        let rig = try Rig()
        let a = try rig.add("Plain title", body: "plain body", tags: ["backend", "삭제"])
        try rig.add("Other", tags: ["frontend"])
        #expect(try rig.ids("backend") == [a])
        #expect(try rig.ids("삭제") == [a])
        #expect(try rig.ids("BACK") == [a])
    }

    @Test func everyTermMustOccurInTitleTagsOrBody() throws {
        let rig = try Rig()
        let a = try rig.add("Rate limit per token", body: "uses a sliding window", tags: ["api"])
        try rig.add("Rate card", body: "pricing")
        try rig.add("Sliding doors", body: "film notes")
        #expect(try rig.ids("rate sliding") == [a])
        #expect(try rig.ids("rate sliding api") == [a])
        #expect(try rig.ids("rate sliding missing") == [])
        #expect(try rig.ids("  rate\tLIMIT  ") == [a])
        #expect(try rig.ids("rate").count == 2)
    }

    @Test func wildcardAndQuoteCharactersAreLiteral() throws {
        let rig = try Rig()
        let percent = try rig.add("Discount", body: "gives 100% off")
        let plain = try rig.add("Discount plain", body: "gives 100 off")
        let underscore = try rig.add("Naming", body: "use snake_case here")
        let other = try rig.add("Naming two", body: "use snakeXcase here")
        let quote = try rig.add("Quotes", body: "she said \"hello there\" loudly")
        let apostrophe = try rig.add("Apostrophe", body: "it's the user's choice")
        let backslash = try rig.add("Paths", body: "C:\\temp\\file")
        let tagOnly = try rig.add("Tag only", tags: ["x"])

        #expect(try rig.ids("100%") == [percent])
        #expect(try rig.ids("%") == [percent])
        #expect(try rig.ids("_") == [underscore])
        #expect(try rig.ids("snake_case") == [underscore])
        #expect(try rig.ids("snake_") == [underscore])
        #expect(try rig.ids("\"") == [quote])
        #expect(try rig.ids("\"hello") == [quote])
        #expect(try rig.ids("\"hello there\"") == [quote])    // two terms, each carrying its own quote
        #expect(try rig.ids("said \"hello") == [quote])
        #expect(try rig.ids("it's") == [apostrophe])
        #expect(try rig.ids("'") == [apostrophe])
        #expect(try rig.ids("user's choice") == [apostrophe])
        #expect(try rig.ids("\\") == [backslash])
        #expect(try rig.ids("temp\\file") == [backslash])
        #expect(try rig.ids("\"\"\"") == [])
        #expect(try rig.ids("a*") == [])
        #expect(try rig.ids("title:x") == [])
        #expect(try rig.ids("NEAR(a b)") == [])
        #expect(try rig.ids("x OR y") == [])
        #expect(![plain, other, tagOnly].contains(where: { _ in false }))
    }

    @Test func userTextNeverReachesTheSQL() throws {
        let rig = try Rig()
        let a = try rig.add("Keep me", body: "important")
        #expect(try rig.ids("'; DROP TABLE records; --") == [])
        #expect(try rig.ids("\") OR 1=1 --") == [])
        #expect(try rig.ids("x' OR '1'='1") == [])
        #expect(try rig.ids("important") == [a])
        #expect(try rig.indexed.count("SELECT count(*) FROM records") == 1)
        #expect(thrown { _ = try rig.indexed.search(SearchQuery(text: "   ")) }?.isInvalid == true)
        #expect(thrown { _ = try rig.indexed.search(SearchQuery(text: "a\0b")) }?.isInvalid == true)
        #expect(thrown { _ = try rig.indexed.search(SearchQuery(text: String(repeating: "x", count: 301))) }?.isInvalid == true)
        // More than eight terms: only the first eight count.
        #expect(try rig.ids("important a b c d e f g h i j").count == 0)
    }

    @Test func filters() throws {
        let rig = try Rig()
        let task = try rig.add("Shared words here", kind: .task, status: .open, tags: ["alpha"])
        let decision = try rig.add("Shared words here", kind: .decision, status: .done, tags: ["beta", "Alpha"])
        let doing = try rig.add("Shared words here", kind: .task, status: .doing)
        let elsewhere = try rig.add("Shared words here", kind: .task, in: rig.other)
        #expect(Set(try rig.ids("shared words")) == [task, decision, doing, elsewhere])
        #expect(Set(try rig.ids("shared words", project: rig.project)) == [task, decision, doing])
        #expect(try rig.ids("shared words", project: rig.other) == [elsewhere])
        #expect(Set(try rig.ids("shared", project: rig.project, kinds: [.task])) == [task, doing])
        #expect(try rig.ids("shared", project: rig.project, kinds: [.decision]) == [decision])
        #expect(Set(try rig.ids("shared", project: rig.project, statuses: [.open, .doing])) == [task, doing])
        #expect(Set(try rig.ids("shared", project: rig.project, tag: "alpha")) == [task, decision])
        #expect(try rig.ids("shared", project: rig.project, kinds: [.task], statuses: [.doing], tag: "alpha") == [])
        #expect(try rig.ids("shared", project: rig.project, tag: "beta") == [decision])
    }

    @Test func limitIsHonoredAndClamped() throws {
        let rig = try Rig()
        for index in 0..<30 { try rig.add("Match number \(index)") }
        for store in [rig.indexed, rig.plain] {
            #expect(try store.search(SearchQuery(text: "match", limit: 5)).count == 5)
            #expect(try store.search(SearchQuery(text: "match", limit: 1000)).count == 30)
            #expect(try store.search(SearchQuery(text: "match", limit: 0)).count == 1)
        }
        #expect(try rig.indexed.search(SearchQuery(text: "match")).count == 20)
    }

    @Test func rankingPrefersTitleMatches() throws {
        let rig = try Rig()
        let bodyOnly = try rig.add("Weekly notes", body: String(repeating: "scheduler ", count: 6))
        let inTitle = try rig.add("Scheduler design", body: "details follow")
        for store in [rig.indexed, rig.plain] {
            #expect(try store.search(SearchQuery(text: "scheduler")).map(\.id).first == inTitle)
        }
        // Without a title match, the newest comes first on the LIKE path.
        try rig.indexed.sql("UPDATE records SET updated_at = id * 1000")
        #expect(try rig.plain.search(SearchQuery(text: "scheduler design")).map(\.id) == [inTitle])
        #expect(try rig.plain.search(SearchQuery(text: "details")).map(\.id) == [inTitle])
        #expect(bodyOnly != inTitle)
    }

    @Test func snippetsAreAroundTheFirstTerm() throws {
        let rig = try Rig()
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 30)
        let id = try rig.add("Long", body: filler + "NEEDLE appears here\n\nand   continues " + filler)
        let short = try rig.add("Short", body: "tiny body")
        let titleOnly = try rig.add("Needle title", body: filler)
        for store in [rig.indexed, rig.plain] {
            let hits = try store.search(SearchQuery(text: "needle"))
            let hit = try #require(hits.first { $0.id == id })
            #expect(hit.snippet.contains("NEEDLE appears here and continues"))
            #expect(hit.snippet.hasPrefix("…") && hit.snippet.hasSuffix("…"))
            #expect(hit.snippet.count <= Limits.snippetChars + 4)
            let title = try #require(hits.first { $0.id == titleOnly })
            #expect(title.snippet.hasPrefix("lorem ipsum"))
            #expect(!title.snippet.hasPrefix("…"))
            #expect(hits.contains { $0.id == short } == false)
        }
        let tiny = try #require(try rig.plain.search(SearchQuery(text: "tiny")).first)
        #expect(tiny.snippet == "tiny body")
        #expect(tiny.record.id == short)
    }

    @Test func searchSeesChangesAndDeletes() throws {
        let rig = try Rig()
        let id = try rig.add("Original wording", body: "alpha beta")
        #expect(try rig.ids("wording") == [id])
        _ = try rig.indexed.update(id: id, RecordPatch(title: "Changed phrase", body: "gamma"))
        #expect(try rig.ids("wording") == [])
        #expect(try rig.ids("phrase gamma") == [id])
        _ = try rig.plain.update(id: id, RecordPatch(append: "delta"))
        #expect(try rig.ids("delta") == [id])
        try rig.indexed.delete(id: id)
        #expect(try rig.ids("phrase") == [])
        try rig.indexed.sql("INSERT INTO records_fts(records_fts) VALUES('integrity-check')")
    }
}
