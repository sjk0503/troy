import Foundation
import Testing
@testable import TroyCore

@Suite struct HelperTests {
    @Test func tagsAreTrimmedDeduplicatedWithoutCaseAndKeepOrder() throws {
        #expect(try TagRules.normalize(["  Swift ", "swift", "", "Core", "CORE", "x"]) == ["Swift", "Core", "x"])
        #expect(thrown { _ = try TagRules.normalize(Array(repeating: "a", count: 1).map { _ in String(repeating: "t", count: 61) }) }?.isInvalid == true)
        #expect(thrown { _ = try TagRules.normalize((0..<21).map { "t\($0)" }) }?.isInvalid == true)
        #expect(thrown { _ = try TagRules.normalize(["a\0b"]) }?.isInvalid == true)
    }

    @Test func recordPathsAreNormalized() throws {
        #expect(PathRules.recordPath("./src/") == "src")
        #expect(PathRules.recordPath("  src//core///a.swift ") == "src/core/a.swift")
        #expect(PathRules.recordPath("src/**/*.ts") == "src")
        #expect(PathRules.recordPath("src/app/ab*") == "src/app")
        #expect(PathRules.recordPath("lib/[ab]/x") == "lib")
        #expect(PathRules.recordPath("*.md") == "")
        #expect(PathRules.recordPath("**/foo") == "")
        #expect(PathRules.recordPath("./") == "")
        #expect(PathRules.recordPath("/abs/dir/") == "/abs/dir")
        #expect(try PathRules.recordPaths(["./src/", "src/**/*.ts", "a.swift", "", "a.swift"]) == ["src", "a.swift"])
    }

    @Test func pathOverlapUsesComponentBoundaries() {
        #expect(PathRules.overlap("src", "src"))
        #expect(PathRules.overlap("src", "src/a/b.swift"))
        #expect(PathRules.overlap("src/a/b.swift", "src"))
        #expect(!PathRules.overlap("src/a", "src/ab"))
        #expect(!PathRules.overlap("src", "srcs"))
        #expect(PathRules.sharedPaths(["src"], ["src/a.swift", "docs"]) == ["src/a.swift"])
    }

    @Test func projectPathsAreAbsoluteAndStandardized() throws {
        #expect(try PathRules.projectPath("/a/b/") == "/a/b")
        #expect(try PathRules.projectPath("/a/./b/../c") == "/a/c")
        #expect(try PathRules.projectPath("~/dev/x") == NSHomeDirectory() + "/dev/x")
        #expect(thrown { _ = try PathRules.projectPath("relative/dir") }?.isInvalid == true)
        #expect(PathRules.contains(ancestor: "/a/b", "/a/b/c"))
        #expect(!PathRules.contains(ancestor: "/a/b", "/a/bc"))
    }

    @Test func searchTermsSplitAndEscape() {
        #expect(SearchTerms.split("  alpha \t beta\ngamma ") == ["alpha", "beta", "gamma"])
        #expect(SearchTerms.split("a b c d e f g h i j k").count == Limits.searchTerms)
        #expect(SearchTerms.likePattern("100%_a\\") == "%100\\%\\_a\\\\%")
        #expect(SearchTerms.ftsPhrase("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(SearchTerms.usesIndex("abc"))
        #expect(!SearchTerms.usesIndex("제한"))
        #expect(SearchTerms.usesIndex("토큰별"))
    }

    @Test func bigramSimilarity() {
        #expect(Similarity.score("Add export command", "add export command") == 1)
        #expect(Similarity.score("", "x") == 0)
        #expect(Similarity.bigrams("a") == Similarity.bigrams("A"))
        #expect(Similarity.bigrams("ab").count == 1)
        #expect(Similarity.bigrams("ab cd, x").count == 3)
        #expect(Similarity.score("토큰별 호출 제한", "토큰을 호출할 때 제한") >= Limits.similarThreshold)
        #expect(Similarity.score("Database migration plan", "토큰별 호출 제한") == 0)
    }

    @Test func ageReadsShort() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        #expect(Age.short(since: now.addingTimeInterval(-5 * 60), now: now) == "5m")
        #expect(Age.short(since: now.addingTimeInterval(-2 * 3600), now: now) == "2h")
        #expect(Age.short(since: now.addingTimeInterval(-3 * 86400), now: now) == "3d")
        #expect(Age.short(since: now.addingTimeInterval(-15 * 86400), now: now) == "2w")
        #expect(Age.short(since: now.addingTimeInterval(-200 * 86400), now: now).contains("-"))
    }
}
