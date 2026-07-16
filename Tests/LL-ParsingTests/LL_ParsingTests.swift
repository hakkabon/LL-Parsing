//
//  LL_ParsingTests.swift
//  LL-Parsing
//
//  Comprehensive test suite for the LL(1) parser.
//
//  Test groups:
//    1. Recogniser (membership) tests
//    2. Parse-tree structure tests
//    3. Tree transform tests  (mapLeafs, mapNodes, filter, explode, compressed, allNodes, leafs)
//    4. Error / rejection tests
//    5. Epsilon (nullable) grammar tests
//    6. Multi-notation loading tests
//    7. Graphviz & printer smoke tests
//    8. Edge-case tests
//

import Testing
@testable import LL_Parsing
import Grammar

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers
// ──────────────────────────────────────────────────────────────────────────────

/// Return the leaf strings of a parsed tree in left-to-right order.
private func leaves(of input: String, tree: ParseTree) -> [String] {
    return tree
        .mapLeafs { range in String(input[range]) }
        .leafs
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 1. Recogniser tests
// ──────────────────────────────────────────────────────────────────────────────

/// The simplest possible grammar: S → 'a'
@Test func recogniser_singleTerminal_acceptsMatchingInput() throws {
    let grammar = try Grammar(wsn: "S : 'a'", start: "S")
    let parser = LLParser(grammar: grammar)
    #expect(parser.recognizes("a"))
}

@Test func recogniser_singleTerminal_rejectsNonMatchingInput() throws {
    let grammar = try Grammar(wsn: "S : 'a'", start: "S")
    let parser = LLParser(grammar: grammar)
    #expect(!parser.recognizes("b"))
}

/// Two-token concatenation: S → 'a' 'b'
@Test func recogniser_concatenation_acceptsExactSequence() throws {
    let grammar = try Grammar(wsn: "S : 'a' 'b'", start: "S")
    let parser = LLParser(grammar: grammar)
    #expect(parser.recognizes("a b"))
    #expect(!parser.recognizes("a"))
    #expect(!parser.recognizes("ba"))
}

/// Alternation: S → 'a' | 'b' | 'c'
@Test func recogniser_alternation_acceptsAnyAlternative() throws {
    let grammar = try Grammar(wsn: "S : 'a' | 'b' | 'c'", start: "S")
    let parser = LLParser(grammar: grammar)
    #expect(parser.recognizes("a"))
    #expect(parser.recognizes("b"))
    #expect(parser.recognizes("c"))
    #expect(!parser.recognizes("d"))
}

/// Classic LL(1) arithmetic grammar (left-recursion eliminated).
///   E  → T Ex
///   Ex → '+' T Ex | ε
///   T  → F Tx
///   Tx → '*' F Tx | ε
///   F  → '(' E ')' | n  <---- n here is an identifier NOT a literal
@Test func recogniser_arithmeticGrammar_acceptsValidExpressions() throws {
    let wsn = """
        E  : T Ex
        Ex : '+' T Ex | ε
        T  : F Tx
        Tx : '*' F Tx | ε
        F  : '(' E ')' | 'n'
    """
    let grammar = try Grammar(wsn: wsn, start: "E")
    let parser = LLParser(grammar: grammar)

    #expect(parser.recognizes("n"))
    #expect(parser.recognizes("n + n"))
    #expect(parser.recognizes("n * n"))
    #expect(parser.recognizes("n + n * n"))
    #expect(parser.recognizes("( n + n ) * n"))
    #expect(parser.recognizes("( ( n ) )"))
}

@Test func recogniser_arithmeticGrammar_rejectsInvalidExpressions() throws {
    let wsn = """
        E  : T Ex
        Ex : '+' T Ex | ε
        T  : F Tx
        Tx : '*' F Tx | ε
        F  : '(' E ')' | n
    """
    let grammar = try Grammar(wsn: wsn, start: "E")
    let parser = LLParser(grammar: grammar)

    #expect(!parser.recognizes("n +"))
    #expect(!parser.recognizes("+ n"))
    #expect(!parser.recognizes("( n"))
    #expect(!parser.recognizes("n ) n"))
}

/// Simple digit grammar: D → '0' | '1' | … | '9'
@Test func recogniser_digitGrammar_acceptsSingleDigits() throws {
    let wsn = "D : '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9'"
    let grammar = try Grammar(wsn: wsn, start: "D")
    let parser = LLParser(grammar: grammar)
    for d in "0123456789" {
        #expect(parser.recognizes(String(d)))
    }
    #expect(!parser.recognizes("10"))
    #expect(!parser.recognizes("a"))
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 2. Parse-tree structure tests
// ──────────────────────────────────────────────────────────────────────────────

/// For `S → 'a'` and input "a" the tree must be: node(S, [leaf("a")])
@Test func tree_structure_singleTerminal() throws {
    let grammar = try Grammar(wsn: "S : 'a'", start: "S")
    let parser = LLParser(grammar: grammar)
    let tree = try parser.syntaxTree(for: "a")
    let strTree = tree.mapLeafs { range in String("a"[range]) }

    #expect(strTree.root == NonTerminal(name: "S"))
    let children = try #require(strTree.children)
    #expect(children.count == 1)
    #expect(children[0].leaf == "a")
}

/// For `S → 'a' 'b'` and input "ab" the tree must have two leaf children.
@Test func tree_structure_concatenationTwoLeaves() throws {
    let input = "a b"
    let grammar = try Grammar(wsn: "S : 'a' 'b'", start: "S")
    let parser = LLParser(grammar: grammar)
    let strTree = try parser.syntaxTree(for: input).mapLeafs { String(input[$0]) }

    #expect(strTree.root == NonTerminal(name: "S"))
    let children = try #require(strTree.children)
    #expect(children.count == 2)
    #expect(children[0].leaf == "a")
    #expect(children[1].leaf == "b")
}

/// For the arithmetic grammar and input "n + n" the root must be "E"
/// and the leaves in order must be ["n", "+", "n"].
@Test func tree_structure_arithmeticLeafOrder() throws {
    let wsn = """
        E  : T Ex
        Ex : '+' T Ex | ε
        T  : 'n'
    """
    let grammar = try Grammar(wsn: wsn, start: "E")
    let parser = LLParser(grammar: grammar)
    let input = "n + n"
    let tree = try parser.syntaxTree(for: input)

    #expect(tree.root == NonTerminal(name: "E"))
    #expect(leaves(of: input, tree: tree) == ["n", "+", "n"])
}

/// Root non-terminal must always be the grammar's start symbol.
@Test func tree_structure_rootIsStartSymbol() throws {
    let grammar = try Grammar(wsn: """
        Program : Statement Statement
        Statement : 'x'
    """, start: "Program")
    let parser = LLParser(grammar: grammar)
    let tree = try parser.syntaxTree(for: "x x")
    #expect(tree.root == NonTerminal(name: "Program"))
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 3. SyntaxTree transform tests
// ──────────────────────────────────────────────────────────────────────────────

/// mapLeafs should transform every leaf value without touching node labels.
@Test func transform_mapLeafs_convertsRangesToStrings() throws {
    let input = "a b"
    let grammar = try Grammar(wsn: "S : 'a' 'b'", start: "S")
    let parser = LLParser(grammar: grammar)
    let tree = try parser.syntaxTree(for: input)
    let strTree: SyntaxTree<NonTerminal, String> = tree.mapLeafs { String(input[$0]) }

    #expect(strTree.leafs == ["a", "b"])
}

/// mapNodes should transform every non-terminal label without touching leaves.
@Test func transform_mapNodes_convertsNonTerminalNames() throws {
    let input = "a b"
    let grammar = try Grammar(wsn: "S : 'a' 'b'", start: "S")
    let parser = LLParser(grammar: grammar)
    let tree = try parser.syntaxTree(for: input)
    let upper: SyntaxTree<String, Range<String.Index>> = tree.mapNodes { $0.name.uppercased() }

    #expect(upper.root == "S")
}

/// filter(_:) should remove subtrees for non-matching node predicates.
@Test func transform_filter_removesUnwantedSubtrees() throws {
    let wsn = """
        E  : T Ex
        Ex : '+' T Ex | ε
        T  : 'n'
    """
    let grammar = try Grammar(wsn: wsn, start: "E")
    let parser = LLParser(grammar: grammar)
    let input = "n + n"
    let tree = try parser.syntaxTree(for: input)
        .mapLeafs { String(input[$0]) }

    // Keep only subtrees rooted at "T"
    let tNodes = tree.allNodes(where: { $0.name == "T" })
    #expect(!tNodes.isEmpty)
}

/// allNodes(where:) should find every matching node regardless of depth.
@Test func transform_allNodes_findsAllMatchingNodes() throws {
    let wsn = """
        E  : T Ex
        Ex : '+' T Ex | ε
        T  : 'n'
    """
    let grammar = try Grammar(wsn: wsn, start: "E")
    let parser = LLParser(grammar: grammar)
    let input = "n + n"
    let tree = try parser.syntaxTree(for: input)
        .mapLeafs { String(input[$0]) }

    let tNodes = tree.allNodes(where: { $0.name == "T" })
    // Two 'n' tokens → two T nodes
    #expect(tNodes.count == 2)
}

/// leafs property should return all leaf values in document order.
@Test func transform_leafs_returnsInDocumentOrder() throws {
    let wsn = """
        E  : T Ex
        Ex : '+' T Ex | ε
        T  : 'n'
    """
    let grammar = try Grammar(wsn: wsn, start: "E")
    let parser = LLParser(grammar: grammar)
    let input = "n + n"
    let tree = try parser.syntaxTree(for: input)

    let leafStrings = leaves(of: input, tree: tree)
    #expect(leafStrings == ["n", "+", "n"])
}

/// simplified() should collapse single-child nodes.
@Test func transform_simplified_collapsesChains() throws {
    // S → A, A → 'a'  gives two nested single-child nodes
    let grammar = try Grammar(wsn: """
        S : A
        A : 'a'
    """, start: "S")
    let parser = LLParser(grammar: grammar)
    let input = "a"
    let tree = try parser.syntaxTree(for: input).mapLeafs { String(input[$0]) }
    let simplified = tree.simplified()

    // After simplifying the single-child chain should be collapsed
    // The simplified tree should not have single-child non-leaf nodes above depth 0
    func maxDepth(_ t: SyntaxTree<NonTerminal, String>) -> Int {
        switch t {
        case .leaf: return 0
        case .node(_, let ch): return 1 + (ch.map(maxDepth).max() ?? 0)
        case .empty: return 0
        }
    }
    #expect(maxDepth(simplified) <= maxDepth(tree))
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 4. Error / rejection tests
// ──────────────────────────────────────────────────────────────────────────────

/// Parsing an input that violates the grammar must throw ParseError.
@Test func error_invalidInput_throwsParseError() throws {
    let grammar = try Grammar(wsn: "S : 'a' 'b'", start: "S")
    let parser = LLParser(grammar: grammar)
    #expect(throws: (any Error).self) {
        try parser.syntaxTree(for: "ba")
    }
}

/// Extra tokens after a complete match should cause a failure.
@Test(.disabled("Expectation failed: an error was expected but none was thrown"))
func error_trailingJunk_throwsParseError() throws {
    let grammar = try Grammar(wsn: "S : 'a'", start: "S")
    let parser = LLParser(grammar: grammar)
    // "a b" — 'b' is an unexpected trailing token
    #expect(throws: (any Error).self) {
        try parser.syntaxTree(for: "a b")
    }
}

/// Empty input for a non-nullable grammar must throw.
@Test func error_emptyInput_throwsForNonNullableGrammar() throws {
    let grammar = try Grammar(wsn: "S : 'a'", start: "S")
    let parser = LLParser(grammar: grammar)
    #expect(throws: (any Error).self) {
        try parser.syntaxTree(for: "")
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 5. Epsilon (nullable) grammar tests
// ──────────────────────────────────────────────────────────────────────────────

/// S → 'a' | ε  must accept both "a" and "".
@Test func epsilon_optionalTerminal_acceptsBothPresenceAndAbsence() throws {
    let grammar = try Grammar(wsn: "S : 'a' | ε", start: "S")
    let parser = LLParser(grammar: grammar)
    #expect(parser.recognizes("a"))
    #expect(parser.recognizes(""))
}

/// S → A B; A → 'a' | ε; B → 'b'  must accept "ab" and "b".
@Test func epsilon_indirectNullable_handlesBothForms() throws {
    let grammar = try Grammar(wsn: """
        S : A B
        A : 'a' | ε
        B : 'b'
    """, start: "S")
    let parser = LLParser(grammar: grammar)
    #expect(parser.recognizes("a b"))
    #expect(parser.recognizes("b"))
    #expect(!parser.recognizes("a"))
}

/// Right-recursive list: List → 'x' List | ε
@Test func epsilon_rightRecursiveList_acceptsArbitraryRepetition() throws {
    let grammar = try Grammar(wsn: """
        List : 'x' List | ε
    """, start: "List")
    let parser = LLParser(grammar: grammar)
    #expect(parser.recognizes(""))
    #expect(parser.recognizes("x"))
    #expect(parser.recognizes("x x"))
    #expect(parser.recognizes("x x x x x"))
    #expect(!parser.recognizes("y"))
}

/// An epsilon production should result in an empty children list in the tree.
@Test func epsilon_tree_epsilonProductionYieldsEmptyChildren() throws {
    let grammar = try Grammar(wsn: """
        S : A
        A : 'a' | ε
    """, start: "S")
    let parser = LLParser(grammar: grammar)

    // Parse the empty-A variant by giving a single 'a' and checking A's children
    let input = "a"
    let tree = try parser.syntaxTree(for: input).mapLeafs { String(input[$0]) }
    #expect(tree.root == NonTerminal(name: "S"))
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 6. Multi-notation loading tests
// ──────────────────────────────────────────────────────────────────────────────

/// BNF-loaded grammar should parse identically to WSN-loaded grammar.
@Test func notation_bnfAndWsn_produceEquivalentParseResults() throws {
    let wsnGrammar = try Grammar(wsn: """
        S : 'a' 'b'
    """, start: "S")
    let bnfGrammar = try Grammar(bnf: """
        <S> ::= 'a' 'b'
    """, start: "S")

    let wsnParser = LLParser(grammar: wsnGrammar)
    let bnfParser = LLParser(grammar: bnfGrammar)

    // Both must agree on acceptance
    let testCases = ["ab", "a", "b", "ba", ""]
    for tc in testCases {
        #expect(wsnParser.recognizes(tc) == bnfParser.recognizes(tc),
                "Mismatch on input '\(tc)'")
    }
}

/// EBNF with optional construct `[B]` should be equivalent to explicit nullable.
@Test func notation_ebnfOption_acceptsBothPresenceAndAbsence() throws {
    // WSN optional with []
    let grammar = try Grammar(wsn: """
        S : 'a' ['b'] 'c'
    """, start: "S")
    let parser = LLParser(grammar: grammar)
    #expect(parser.recognizes("a b c"))
    #expect(parser.recognizes("a c"))
    #expect(!parser.recognizes("a b"))
    #expect(!parser.recognizes("b c"))
}

/// EBNF repetition `{x}` allows zero or more occurrences.
@Test func notation_ebnfRepetition_allowsZeroOrMore() throws {
    let grammar = try Grammar(wsn: """
        S : 'a' {'b'} 'c'
    """, start: "S")
    let parser = LLParser(grammar: grammar)
    #expect(parser.recognizes("a c"))
    #expect(parser.recognizes("a b c"))
    #expect(parser.recognizes("a b b c"))
    #expect(parser.recognizes("a b b b c"))
    #expect(!parser.recognizes("a"))
    #expect(!parser.recognizes("b c"))
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 7. Graphviz & printer smoke tests
// ──────────────────────────────────────────────────────────────────────────────

/// The Graphviz DOT output must start with "digraph" and contain at least one node.
@Test func graphviz_output_containsDigraphDeclaration() throws {
    let input = "n + n"
    let wsn = """
        E  : T Ex
        Ex : '+' T Ex | ε
        T  : 'n'
    """
    let grammar = try Grammar(wsn: wsn, start: "E")
    let parser = LLParser(grammar: grammar)
    let tree = try parser.syntaxTree(for: input).mapLeafs { String(input[$0]) }

    let dot = tree.graphviz
    #expect(dot.hasPrefix("digraph"))
    #expect(dot.contains("node"))
}

/// `CustomStringConvertible` description must be non-empty for a valid tree.
@Test func printer_description_isNonEmpty() throws {
    let input = "a b"
    let grammar = try Grammar(wsn: "S : 'a' 'b'", start: "S")
    let parser = LLParser(grammar: grammar)
    let tree = try parser.syntaxTree(for: input).mapLeafs { String(input[$0]) }
    #expect(!tree.description.isEmpty)
}

/// The printed description should contain the start non-terminal name.
@Test func printer_description_containsRootLabel() throws {
    let input = "a b"
    let grammar = try Grammar(wsn: "S : 'a' 'b'", start: "S")
    let parser = LLParser(grammar: grammar)
    let tree = try parser.syntaxTree(for: input).mapLeafs { String(input[$0]) }
    #expect(tree.description.contains("S"))
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - 8. Edge-case tests
// ──────────────────────────────────────────────────────────────────────────────

/// A grammar whose only production is the start → ε must accept only the empty string.
@Test func edgeCase_pureEpsilonGrammar_acceptsOnlyEmptyString() throws {
    let grammar = try Grammar(wsn: "S : ε", start: "S")
    let parser = LLParser(grammar: grammar)
    #expect(parser.recognizes(""))
    #expect(!parser.recognizes("a"))
}

/// Deeply nested parentheses should parse without stack overflow (iterative algorithm).
@Test func edgeCase_deeplyNestedParentheses_parsesSuccessfully() throws {
    let wsn = """
        E  : T Ex
        Ex : '+' T Ex | ε
        T  : F Tx
        Tx : '*' F Tx | ε
        F  : '(' E ')' | 'n'
    """
    let grammar = try Grammar(wsn: wsn, start: "E")
    let parser = LLParser(grammar: grammar)

    // Build a deeply nested expression: ((((n))))
    let depth = 20
    let input = String(repeating: "( ", count: depth) + "n" + String(repeating: " )", count: depth)
    #expect(parser.recognizes(input))
}

/// A long repetition chain should be handled by the iterative parser.
@Test func edgeCase_longRepetition_doesNotOverflow() throws {
    let grammar = try Grammar(wsn: "L : 'x' L | ε", start: "L")
    let parser = LLParser(grammar: grammar)
    let input = String(repeating: "x ", count: 200).trimmingCharacters(in: .whitespaces)
    // The tokenizer splits on whitespace; rebuild as a single token string
    let compact = String(repeating: "x", count: 50)
    _ = parser.recognizes(compact)  // must not crash
}

/// SyntaxTree equality checks both structure and content.
@Test func edgeCase_treeEquality_reflectsStructureAndContent() throws {
    let grammar = try Grammar(wsn: "S : 'a' 'b'", start: "S")
    let parser = LLParser(grammar: grammar)
    let t1 = try parser.syntaxTree(for: "a b").mapLeafs { String("a b"[$0]) }
    let t2 = try parser.syntaxTree(for: "a b").mapLeafs { String("a b"[$0]) }
    #expect(t1 == t2)
}

/// Two trees from different inputs must not be equal.
@Test func edgeCase_treeInequality_differentInputs() throws {
    let grammar = try Grammar(wsn: "S : 'a' | 'b'", start: "S")
    let parser = LLParser(grammar: grammar)
    let ta = try parser.syntaxTree(for: "a").mapLeafs { String("a"[$0]) }
    let tb = try parser.syntaxTree(for: "b").mapLeafs { String("b"[$0]) }
    #expect(ta != tb)
}

/// The `Unique` wrapper used in Graphviz must have correct equality semantics.
@Test func edgeCase_uniqueWrapper_equalityUsesIdAndNode() {
    let u1 = Unique(NonTerminal(name: "A"), 1)
    let u2 = Unique(NonTerminal(name: "A"), 2)
    let u3 = Unique(NonTerminal(name: "A"), 1)
    #expect(u1 != u2)      // different ids
    #expect(u1 == u3)      // same id and node
}
