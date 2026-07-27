//
//  ErrorRecoveryTests.swift
//  LL-Parsing
//
//  Tests for LLParser.parseWithRecovery, SyntaxError, and DiagnosticReporter.
//
//  Test groups:
//    1. Parity with the throwing parser on valid input
//    2. Terminal-mismatch recovery (insertion / deletion)
//    3. Non-terminal prediction-failure recovery (panic mode, FIRST/FOLLOW resync)
//    4. Unrecoverable input
//    5. Diagnostics bookkeeping
//    6. SyntaxError / DiagnosticReporter unit tests
//

import Testing
@testable import LL_Parsing
import Grammar
import Parser

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers
// ──────────────────────────────────────────────────────────────────────────────

/// `SyntaxTree`'s `==` only handles `.leaf`/`.leaf` and `.node`/`.node`; two
/// `.empty` trees compare unequal (falls through to `default: return false`).
/// Recovery uses `.empty` as its placeholder for an assumed-missing terminal
/// or an abandoned non-terminal, so tests need a direct pattern match instead
/// of `==` to check for it.
private func isEmpty(_ tree: ParseTree) -> Bool {
    if case .empty = tree { return true }
    return false
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 1. Parity with the throwing parser on valid input
// ──────────────────────────────────────────────────────────────────────────────

/// On fully valid input, `parseWithRecovery` should report no diagnostics and
/// build exactly the same tree `syntaxTree(for:)` does.
@Test func recovery_validInput_matchesThrowingParseAndReportsNoDiagnostics() throws {
    let wsn = """
        E  : T Ex
        Ex : '+' T Ex | ε
        T  : 'n'
    """
    let grammar = try Grammar(wsn: wsn, start: "E")
    let parser = LLParser(grammar: grammar)
    let input = "n + n"

    let thrownTree = try parser.syntaxTree(for: input)
    let recoveredTree = parser.parseWithRecovery(input)

    #expect(parser.diagnostics.isEmpty)
    #expect(recoveredTree != nil)
    #expect(recoveredTree == thrownTree)
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 2. Terminal-mismatch recovery
// ──────────────────────────────────────────────────────────────────────────────

/// A single missing token should be reported once and treated as inserted:
/// parsing continues without consuming input, and the tree keeps a `.empty`
/// placeholder in the missing token's position so sibling counts stay
/// correct.
@Test func recovery_missingToken_insertsPlaceholderAndContinues() throws {
    let grammar = try Grammar(wsn: "S : 'a' 'b' 'c'", start: "S")
    let parser = LLParser(grammar: grammar)

    let tree = try #require(parser.parseWithRecovery("a c"))

    #expect(parser.diagnostics.count == 1)
    #expect(parser.diagnostics[0].reason == .missingToken)

    #expect(tree.root == NonTerminal(name: "S"))
    let children = try #require(tree.children)
    #expect(children.count == 3)
    #expect(isEmpty(children[1]))
}

/// A single stray extra token — where the token right after it is the one
/// actually expected — should be reported once and deleted, recovering the
/// full, correct tree with no placeholders.
@Test func recovery_extraToken_deletesStrayTokenAndContinues() throws {
    let grammar = try Grammar(wsn: "S : 'a' 'b'", start: "S")
    let parser = LLParser(grammar: grammar)
    let input = "a x b"

    let tree = try #require(parser.parseWithRecovery(input))

    #expect(parser.diagnostics.count == 1)
    #expect(parser.diagnostics[0].reason == .extraToken)

    let strTree = tree.mapLeafs { String(input[$0]) }
    #expect(strTree.root == NonTerminal(name: "S"))
    let children = try #require(strTree.children)
    #expect(children.map(\.leaf) == ["a", "b"])
}

/// Several independent mistakes in one input should all be reported from a
/// single call — the headline feature of panic-mode recovery over the
/// throw-on-first-error parser.
@Test func recovery_multipleIndependentErrors_areAllCollectedInOnePass() throws {
    let grammar = try Grammar(wsn: "S : 'a' 'b' 'c' 'd'", start: "S")
    let parser = LLParser(grammar: grammar)

    // 'b' is missing (next real token is 'c', not 'b'); the stray 'x' before
    // 'c' resolves as a deletion because 'c' immediately follows it; 'd' is
    // missing at the end (trailing 'y' doesn't match, and there's nothing
    // after it either).
    let tree = try #require(parser.parseWithRecovery("a x c y"))

    #expect(parser.diagnostics.count == 3)
    #expect(parser.diagnostics.map(\.reason) == [.missingToken, .extraToken, .missingToken])

    let children = try #require(tree.children)
    #expect(children.count == 4)
    #expect(isEmpty(children[1]))   // missing 'b'
    #expect(!isEmpty(children[2]))  // recovered 'c'
    #expect(isEmpty(children[3]))   // missing 'd'
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 3. Non-terminal prediction-failure recovery
// ──────────────────────────────────────────────────────────────────────────────

/// When a non-terminal has no viable production for the lookahead, and no
/// synchronizing token turns up before end-of-input, but end-of-input itself
/// is in FOLLOW of the non-terminal (as it always is, transitively, for the
/// grammar's start symbol), recovery should treat the non-terminal as having
/// matched nothing and still produce a tree for everything parsed so far.
@Test func recovery_noViableAlternative_resyncsViaEndOfInputInFollowSet() throws {
    let grammar = try Grammar(wsn: "L : 'x' L | ε", start: "L")
    let parser = LLParser(grammar: grammar)

    // Two well-formed 'x's, then a stray 'y' that belongs to no production
    // of L and isn't followed by anything recoverable either.
    let tree = try #require(parser.parseWithRecovery("x x y"))

    #expect(parser.diagnostics.count == 1)
    #expect(parser.diagnostics[0].reason == .noViableAlternative)

    #expect(tree.root == NonTerminal(name: "L"))
    let outerChildren = try #require(tree.children)
    #expect(outerChildren.count == 2)
    #expect(outerChildren[0].leaf != nil) // first 'x'

    let innerChildren = try #require(outerChildren[1].children)
    #expect(innerChildren.count == 2)
    #expect(innerChildren[0].leaf != nil) // second 'x'
    #expect(isEmpty(innerChildren[1]))    // 'y' couldn't be recovered into L
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 4. Unrecoverable input
// ──────────────────────────────────────────────────────────────────────────────

/// If a non-terminal's FOLLOW set doesn't include end-of-input, running out
/// of input while trying to predict it is unrecoverable: recovery reports
/// `.prematureEndOfInput` and gives up rather than looping forever.
///
/// (Empty input alone isn't enough to exercise this: the very first
/// non-terminal processed is always the grammar's start symbol, and
/// FOLLOW(start) always contains end-of-input by construction — so an
/// immediately-empty input always resolves gracefully via that FOLLOW set
/// instead. `A` here only runs out of input *after* `'p'` has already been
/// matched, at a point where FOLLOW(A) = {'z'}, not end-of-input.)
@Test func recovery_prematureEndOfInput_reportedWhenNoSyncTokenExists() throws {
    let grammar = try Grammar(wsn: """
        S : 'p' A 'z'
        A : 'x' | 'y'
    """, start: "S")
    let parser = LLParser(grammar: grammar)

    let tree = parser.parseWithRecovery("p")

    // 'p' was matched, but S's own `.reduce` never fires, so whatever comes
    // back is at best a bare fragment, never a completed S node.
    #expect(tree?.root == nil)
    #expect(parser.diagnostics.contains { $0.reason == .prematureEndOfInput })
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 5. Diagnostics bookkeeping
// ──────────────────────────────────────────────────────────────────────────────

/// `diagnostics` reflects only the most recent `parseWithRecovery` call.
@Test func recovery_diagnostics_areClearedBetweenCalls() throws {
    let grammar = try Grammar(wsn: "S : 'a' 'b'", start: "S")
    let parser = LLParser(grammar: grammar)

    _ = parser.parseWithRecovery("a x b")
    #expect(!parser.diagnostics.isEmpty)

    _ = parser.parseWithRecovery("a b")
    #expect(parser.diagnostics.isEmpty)
}

/// `parse(_:)` / `syntaxTree(for:)` are unaffected by recovery: they still
/// throw on the very first problem, regardless of any prior
/// `parseWithRecovery` call on the same parser instance.
@Test func recovery_doesNotChangeThrowingParseBehavior() throws {
    let grammar = try Grammar(wsn: "S : 'a' 'b'", start: "S")
    let parser = LLParser(grammar: grammar)

    _ = parser.parseWithRecovery("a x b") // populates diagnostics

    #expect(throws: (any Error).self) {
        try parser.syntaxTree(for: "a x b")
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 6. SyntaxError / DiagnosticReporter unit tests
// ──────────────────────────────────────────────────────────────────────────────

@Test func syntaxError_lineAndColumn_computedFromRange() throws {
    let source = "first\nsecond\nthird"
    // "second" starts right after the first newline: line 2, column 1.
    let lineTwoStart = source.index(after: source.firstIndex(of: "\n")!)
    let range = lineTwoStart..<source.index(lineTwoStart, offsetBy: 6)

    let error = SyntaxError(reason: .unexpectedToken, message: "test", range: range, source: source)

    #expect(error.line == 2)
    #expect(error.column == 1)
}

@Test func syntaxError_lineAndColumn_fallsBackToEndOfSourceWhenRangeIsNil() throws {
    let source = "abc"
    let error = SyntaxError(reason: .prematureEndOfInput, message: "test", range: nil, source: source)

    #expect(error.line == 1)
    #expect(error.column == source.count + 1)
}

@Test func syntaxError_description_formatsLineColumnAndMessage() throws {
    let source = "abc"
    let range = source.startIndex..<source.index(after: source.startIndex)
    let error = SyntaxError(reason: .unexpectedToken, message: "something went wrong", range: range, source: source)

    #expect(error.description == "[1:1] Error: something went wrong")
}

@Test func diagnosticReporter_string_includesCountLineNumberAndMessage() throws {
    let grammar = try Grammar(wsn: "S : 'a' 'b' 'c' 'd'", start: "S")
    let parser = LLParser(grammar: grammar)
    _ = parser.parseWithRecovery("a x c y")

    let report = DiagnosticReporter().string(for: parser.diagnostics)

    #expect(report.contains("Found 3 errors:"))
    #expect(report.contains("Line 1"))
    #expect(report.contains("-->"))
    #expect(report.contains("|"))
    for error in parser.diagnostics {
        #expect(report.contains(error.message))
    }
}

@Test func diagnosticReporter_string_isEmptyForNoDiagnostics() throws {
    #expect(DiagnosticReporter().string(for: []).isEmpty)
}
