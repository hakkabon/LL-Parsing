import XCTest
@testable import LL_Parsing

final class LLRegionMemoizerTests: XCTestCase {
    func testReusesRegionAndRelocatesRecoveryEvidence() {
        let old = tokens(offset: 0)
        var first = Memoizer()
        first.record(
            rule: .expression, tokens: old, startIndex: 0, endIndex: 2,
            node: Value(offset: 0),
            effects: LLRegionEffects(
                diagnostics: [Value(offset: 1)],
                recoveries: [Repair(token: old[1], offset: 1)],
                expectations: [Value(offset: 2)]))

        let moved = tokens(offset: 5)
        var second = Memoizer(previous: first.result)
        let hit = second.reuse(rule: .expression, tokens: moved, at: 0)

        XCTAssertEqual(hit?.consumedTokenCount, 2)
        XCTAssertEqual(hit?.node.offset, 5)
        XCTAssertEqual(hit?.effects.diagnostics.first?.offset, 6)
        XCTAssertEqual(hit?.effects.recoveries.first?.token.offset, 6)
        XCTAssertEqual(hit?.effects.expectations.first?.offset, 7)
    }

    func testRelativeOffsetDriftInvalidatesOtherwiseStableTokens() {
        let old = tokens(offset: 0)
        var first = Memoizer()
        first.record(
            rule: .expression, tokens: old, startIndex: 0, endIndex: 2,
            node: Value(offset: 0),
            effects: LLRegionEffects(diagnostics: [], recoveries: [], expectations: []))
        var changed = tokens(offset: 0)
        changed[1] = TestToken(id: changed[1].id, offset: 2)
        changed[2] = TestToken(id: changed[2].id, offset: 3)

        var second = Memoizer(previous: first.result)
        XCTAssertNil(second.reuse(rule: .expression, tokens: changed, at: 0))
    }

    private func tokens(offset: Int) -> [TestToken] {
        [TestToken(id: "a", offset: offset),
         TestToken(id: "b", offset: offset + 1),
         TestToken(id: "eof", offset: offset + 2)]
    }
}

private enum Rule: Hashable, Sendable { case expression }

private struct TestToken: LLRegionToken, Equatable {
    let id: String
    let offset: Int
    var regionTokenID: String { id }
    var regionSourceOffset: Int { offset }
}

private struct Value: LLRegionRelocatable, Equatable {
    let offset: Int
    func relocated(by delta: Int) -> Value { Value(offset: offset + delta) }
}

private struct Repair: LLRegionRecovery, Equatable {
    let token: TestToken
    let offset: Int

    func relocated(by delta: Int,
                   currentTokens: [String: TestToken]) -> Repair {
        Repair(token: currentTokens[token.id]
            ?? TestToken(id: token.id, offset: token.offset + delta),
               offset: offset + delta)
    }
}

private typealias Cache = LLRegionCache<
    Rule, TestToken, Value, Value, Repair, Value>
private typealias Memoizer = LLRegionMemoizer<
    Rule, TestToken, Value, Value, Repair, Value>
