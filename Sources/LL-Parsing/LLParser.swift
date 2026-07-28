//
//  LLParser.swift
//  LL-Parsing
//
//  Created by Ulf Akerstedt-Inoue on 2025/10/26.
//  Copyright © 2025 hakkabon software. All rights reserved.
//

import Foundation
import Grammar
import Lexer
import Parser
import OSLog

/// An unrecovered failure from ``LLParser/parse(_:)`` or
/// ``LLParser/syntaxTree(for:)``.
///
/// Use ``LLParser/parseWithRecovery(_:)`` when syntax diagnostics should be
/// collected instead of stopping at the first error.
public enum ParseError: Error, Equatable {
    case runtimeError(String)
    case tokenError(String)
    case noTokenError(String)
}

extension ParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .runtimeError(let message), .tokenError(let message), .noTokenError(let message):
            return message
        }
    }
}

public class LLParser: DeterministicParser {
    // Internal stack items: Either a symbol to match/expand, or a marker to build a tree node
     private enum StackItem {
         case symbol(Symbol)
         case reduce(parent: NonTerminal, childCount: Int)
     }
    
    let grammar: Grammar
    var (first, follow): ([Symbol : Set<Symbol>], [NonTerminal : Set<Symbol>])
    var groupedProductions: [NonTerminal: [Production]]
    let eps: Symbol // epsilon symbol
    let eof: Symbol // eof terminal
    let symbols = ["|", "\\", "^", ":", ",", "$", ".", "\"", "¶", ">", "#", "+", "-", "{","[", "<", "(",
                   "'", "}", "]", ":]", ")", ";", "/", "*", "?", "??", ":="]
    let keywords: [String] = []

    /// Diagnostics collected by the most recent call to `parseWithRecovery`.
    /// Cleared at the start of every such call; unaffected by `parse(_:)`/
    /// `syntaxTree(for:)`, which throw on the first error instead.
    public private(set) var diagnostics: [SyntaxError] = []
    private let diagnosticReporter = DiagnosticReporter()

    public init(grammar: Grammar) {
        self.grammar = grammar
        (first,follow) = grammar.firstAndFollow()
        groupedProductions = Dictionary(grouping: grammar.productions, by: \.goal)
        eps = .terminal(.meta(grammar.epsilon))
        eof = .terminal(.meta(grammar.endofile))
    }
    
    public func syntaxTree(for string: String) throws -> ParseTree {
        return try parse(string)
    }

    /// Interprets a source character stream by using the LL(1) parsing algorithm.
    ///
    /// Tokenizes `source` with GrammarTokenizer's general-purpose `Tokenizer`
    /// (configured with this parser's fixed `symbols` list), then delegates
    /// to `parse(stream:)`.
    public func parse(_ source: String) throws -> ParseTree {
        try parse(stream: TokenizerStream(source: source, symbols: Set(symbols), keywords: Set(keywords)))
    }

    /// Interprets any `TokenStream` using the LL(1) parsing algorithm.
    ///
    /// The DFA-driven `LexerTokenStream` (built via a `LexerBuilder`
    /// bootstrapped from a `GrammarVocabulary`) and the hand-written
    /// `TokenizerStream` are both accepted interchangeably, as is any other
    /// conformance.
    ///
    /// - Parameter stream: A positioned sequence of tokens, each resolvable
    ///   to a `Terminal` and a source `Range<String.Index>`.
    public func parse<S: TokenStream>(stream: S) throws -> ParseTree {
        var cursor = StreamCursor(stream: stream)

        // Parse Stack (Control Flow)
        var parseStack = Stack<StackItem>()
        
        // Result Stack (Tree Construction). Completed sub-trees are pushed here.
        var resultStack = [ParseTree]()
        
        // Setup Stacks
        parseStack.push(.symbol(eof))
        parseStack.push(.symbol(.nonTerminal(grammar.start)))
        
        // Loop until the stack is empty or we explicitly break
        while let predictedItem = parseStack.pop() {

            Logger.ll.trace("Current predicted \(String(describing: predictedItem)) item")
            
            switch predictedItem {
                
            // We finished processing children for a NonTerminal, now build the node.
            case .reduce(let nonTerminal, let childCount):
                var children: [ParseTree] = []
                // Pop the specific number of children from the result stack
                // Note: They were pushed in order, so we pop from end (reverse)
                if childCount > 0 {
                    let range = (resultStack.count - childCount)..<resultStack.count
                    children = Array(resultStack[range])
                    resultStack.removeSubrange(range)
                }
                
                // Create the node and push back to result stack as a single unit
                let newNode = ParseTree.node(nonTerminal, children: children)
                resultStack.append(newNode)
                
            case .symbol(let predictedSymbol):
                
                if case .metaSymbol(let meta) = predictedSymbol {
                    throw ParseError.runtimeError("Parsed illegal meta symbol \(meta) in input source.")
                }
                
                if case .terminal(let t) = predictedSymbol, t == .meta(.eof) {
                    let (lookahead, _) = try cursor.peek()
                    guard lookahead == .meta(.eof) else {
                        throw ParseError.runtimeError("Unexpected trailing token: \(lookahead).")
                    }
                    guard resultStack.count == 1, let tree = resultStack.first else {
                        throw ParseError.runtimeError("Could not build a single complete syntax tree.")
                    }
                    return tree
                }
                
                if case .terminal(let terminal) = predictedSymbol {
                    // Need to match current token
                    let (tokenTerminal, range) = try cursor.peek()
                    // `terminal` is the grammar's expected terminal (possibly a
                    // regex/range/list terminal resolved from a `lexical { }`
                    // declaration); `tokenTerminal` is the concrete lexeme the
                    // cursor produced. matches(_:) is the asymmetric pattern-vs-
                    // lexeme check meant for this; plain == is strict structural
                    // equality and won't accept a token against a pattern terminal.
                    guard terminal.matches(tokenTerminal) else {
                        throw ParseError.runtimeError("Expected \(terminal), but found token: \(tokenTerminal).")
                    }
                    
                    Logger.ll.trace("Matched \(predictedSymbol) with current token \(tokenTerminal).")
                    
                    // Create Leaf Node
                    resultStack.append(range.map(ParseTree.leaf) ?? .empty)
                    
                    // Advance stream
                    cursor.advance()
                }
                
                if case .nonTerminal(let nt) = predictedSymbol {
                    guard let production = try predict(A: nt, cursor: cursor) else {
                        let (terminal, _) = try cursor.peek()
                        throw ParseError.runtimeError("Prediction not possible for \(nt) with current token: \(terminal).")
                    }
                    
                    // Filter out Epsilon from RHS so we don't try to match it against tokens
                    // If rule is A -> epsilon, validSymbols is empty.
                    let validSymbols = production.rule.filter { $0 != eps }
                    
                    // 1. Push the "Reduce" marker first (so it is processed LAST)
                    // This will eventually gather the children we are about to push
                    parseStack.push(.reduce(parent: nt, childCount: validSymbols.count))
                    
                    // 2. Push symbols in reverse order (so they are processed FIRST)
                    for symbol in validSymbols.reversed() {
                        parseStack.push(.symbol(symbol))
                    }
                }
            }
        }
        throw ParseError.runtimeError("Could not build syntax tree.")
    }

    // MARK: - Error Recovery

    /// Prints the diagnostics collected by the most recent `parseWithRecovery`
    /// call, in the same "rustc-style" format `Grammar`'s `GrammarParser` uses
    /// for its own diagnostics. Does nothing if there are none.
    public func printDiagnostics() {
        diagnosticReporter.report(diagnostics: diagnostics)
    }

    /// Interprets a source character stream the same way `parse(_:)` does,
    /// except that a syntax error does not stop parsing: it is recorded in
    /// `diagnostics`, and panic-mode recovery attempts to continue from
    /// wherever the grammar's FIRST/FOLLOW sets suggest parsing can safely
    /// resume. This means a single call can surface more than one mistake,
    /// at the cost of the returned tree only being a best-effort
    /// approximation of what a fully well-formed input would have produced.
    ///
    /// `diagnostics` is cleared at the start of every call. Inspect it (or
    /// call `printDiagnostics()`) after this returns to see what, if
    /// anything, went wrong.
    ///
    /// - Returns: A best-effort parse tree, or `nil` if recovery could not
    ///   proceed far enough to produce one (e.g. input ended while a
    ///   non-terminal was still being expanded, with no synchronizing token
    ///   ever found).
    public func parseWithRecovery(_ source: String) -> ParseTree? {
        parseWithRecovery(stream: TokenizerStream(source: source, symbols: Set(symbols), keywords: Set(keywords)))
    }

    /// Interprets any `TokenStream` the same way `parse(stream:)` does,
    /// except that it recovers from syntax errors instead of throwing on
    /// the first one. See `parseWithRecovery(_:)` for the full picture, and
    /// the README's "Error Recovery" section for the panic-mode algorithm
    /// itself, which follows the standard predictive-
    /// parser recovery scheme (Aho, Sethi & Ullman, *Compilers: Principles,
    /// Techniques, and Tools*, §4.4.3):
    ///
    /// - A **terminal** on top of the stack that doesn't match the current
    ///   token is reported, then treated as though it had been *inserted*:
    ///   parsing proceeds without consuming input, so the current token
    ///   gets a fresh chance to match whatever comes next. If the token
    ///   immediately *after* the current one would have matched instead,
    ///   the current token is treated as *extra* and deleted, which
    ///   recovers better from a single stray token than blind insertion
    ///   would.
    /// - A **non-terminal** `A` on top of the stack with no production
    ///   whose FIRST (or FOLLOW, for a nullable production) set contains
    ///   the lookahead is reported, then input tokens are *deleted* (skipped)
    ///   until one is found in FIRST(A) ∪ FOLLOW(A) — the classic
    ///   synchronizing set. Landing in FIRST(A) retries `A`'s prediction;
    ///   landing in FOLLOW(A) (including end-of-input, which is always
    ///   implicitly a member) treats `A` as having matched nothing and
    ///   resumes with whatever follows it. Never finding a synchronizing
    ///   token before end-of-input is the one case recovery gives up on.
    ///
    /// Recovery-synthesized subtrees (an assumed-missing terminal, or a
    /// non-terminal that was abandoned via FOLLOW resynchronization) are
    /// represented as `.empty` in the returned tree, rather than as a
    /// `.node(_, children: [])` — that shape is reserved for a *genuine*
    /// epsilon derivation, so the two stay visually and structurally
    /// distinguishable when inspecting a recovered tree.
    public func parseWithRecovery<S: TokenStream>(stream: S) -> ParseTree? {
        diagnostics.removeAll()

        var cursor = StreamCursor(stream: stream)
        var parseStack = Stack<StackItem>()
        var resultStack = [ParseTree]()

        // The chain of non-terminals currently being expanded, outermost
        // first, used only to annotate diagnostics with useful context
        // (e.g. "while parsing Term, inside Expr"). Pushed when a
        // non-terminal starts being expanded; popped either by its own
        // `.reduce` marker firing normally, or, on the FOLLOW-resync path
        // below, immediately, since no `.reduce` will ever fire for it.
        var contextStack: [NonTerminal] = []

        parseStack.push(.symbol(eof))
        parseStack.push(.symbol(.nonTerminal(grammar.start)))

        var finalTree: ParseTree?

        // A retry (re-pushing the same symbol after a recovery step) is
        // always paired with either consuming a token or narrowing the
        // remaining input, so this loop terminates in the ordinary case.
        // This bound is a defensive backstop against an ill-formed or
        // pathologically self-referential grammar causing it not to —
        // generous enough never to be hit by legitimate recovery, since
        // each real token is visited at most a handful of times.
        let maxIterations = max(10_000, stream.count * 16)
        var iterations = 0

        parseLoop: while let predictedItem = parseStack.pop() {
            iterations += 1
            if iterations > maxIterations {
                diagnostics.append(SyntaxError(
                    reason: .prematureEndOfInput,
                    message: "Error recovery aborted after \(maxIterations) steps without finishing; the grammar or input may not be recoverable.",
                    range: nil,
                    context: contextStack,
                    source: stream.source))
                break parseLoop
            }
            switch predictedItem {

            case .reduce(let nonTerminal, let childCount):
                var children: [ParseTree] = []
                if childCount > 0 {
                    let range = (resultStack.count - childCount)..<resultStack.count
                    children = Array(resultStack[range])
                    resultStack.removeSubrange(range)
                }
                resultStack.append(.node(nonTerminal, children: children))
                if contextStack.last == nonTerminal {
                    contextStack.removeLast()
                }

            case .symbol(let predictedSymbol):

                if case .metaSymbol(let meta) = predictedSymbol {
                    // Not a syntax error in the input — an invariant the
                    // grammar's own rewriting is supposed to guarantee.
                    // There's no sensible way to resynchronize from this,
                    // so report it and stop.
                    diagnostics.append(SyntaxError(
                        reason: .unmatchedPattern,
                        message: "Internal error: illegal meta symbol \(meta) reached during parsing.",
                        range: nil,
                        context: contextStack,
                        source: stream.source))
                    break parseLoop
                }

                if case .terminal(let t) = predictedSymbol, t == .meta(.eof) {
                    // The EOF marker is part of the parse stack, not a token
                    // that may blindly succeed. Discard and diagnose every
                    // remaining input token before completing the parse.
                    while true {
                        let peeked: (terminal: Terminal, range: Range<String.Index>?)
                        do {
                            peeked = try cursor.peek()
                        } catch {
                            diagnostics.append(SyntaxError(
                                reason: .invalidToken,
                                message: "Invalid trailing token in input: \(error)",
                                range: nil,
                                context: contextStack,
                                expected: [.meta(.eof)],
                                source: stream.source))
                            cursor.advance()
                            continue
                        }

                        guard peeked.terminal != .meta(.eof) else { break }
                        diagnostics.append(SyntaxError(
                            reason: .extraToken,
                            message: "Unexpected trailing \(peeked.terminal). Skipping it.",
                            range: peeked.range,
                            context: contextStack,
                            expected: [.meta(.eof)],
                            found: peeked.terminal,
                            source: stream.source))
                        cursor.advance()
                    }

                    finalTree = resultStack.count == 1 ? resultStack.first : nil
                    break parseLoop
                }

                if case .terminal(let terminal) = predictedSymbol {
                    let peeked: (terminal: Terminal, range: Range<String.Index>?)
                    do {
                        peeked = try cursor.peek()
                    } catch {
                        // Lexical error right where we need a token: report
                        // it, skip the offending token, and retry matching
                        // the same terminal against whatever comes next.
                        diagnostics.append(SyntaxError(
                            reason: .invalidToken,
                            message: "Invalid token in input: \(error)",
                            range: nil,
                            context: contextStack,
                            source: stream.source))
                        cursor.advance()
                        parseStack.push(.symbol(predictedSymbol))
                        continue
                    }

                    if terminal.matches(peeked.terminal) {
                        resultStack.append(peeked.range.map(ParseTree.leaf) ?? .empty)
                        cursor.advance()
                    } else if terminal.matches(cursor.peek(ahead: 1).terminal) {
                        // The token right after this one is the one we
                        // wanted: the current token looks like a stray
                        // extra one. Delete it and retry.
                        diagnostics.append(SyntaxError(
                            reason: .extraToken,
                            message: "Unexpected \(peeked.terminal) found. Skipping it.",
                            range: peeked.range,
                            context: contextStack,
                            expected: [terminal],
                            found: peeked.terminal,
                            source: stream.source))
                        cursor.advance()
                        parseStack.push(.symbol(predictedSymbol))
                    } else {
                        // Otherwise assume the expected token was simply
                        // missing: proceed as though it had been inserted,
                        // without consuming input.
                        diagnostics.append(SyntaxError(
                            reason: .missingToken,
                            message: "Expected \(terminal), but found \(peeked.terminal). Assuming \(terminal) was missing.",
                            range: peeked.range,
                            context: contextStack,
                            expected: [terminal],
                            found: peeked.terminal,
                            source: stream.source))
                        resultStack.append(.empty)
                    }
                }

                if case .nonTerminal(let nt) = predictedSymbol {
                    contextStack.append(nt)

                    let production: Production?
                    do {
                        production = try predict(A: nt, cursor: cursor)
                    } catch {
                        diagnostics.append(SyntaxError(
                            reason: .invalidToken,
                            message: "Invalid token in input: \(error)",
                            range: nil,
                            context: contextStack,
                            source: stream.source))
                        cursor.advance()
                        parseStack.push(.symbol(predictedSymbol))
                        contextStack.removeLast()
                        continue
                    }

                    if let production {
                        let validSymbols = production.rule.filter { $0 != eps }
                        parseStack.push(.reduce(parent: nt, childCount: validSymbols.count))
                        for symbol in validSymbols.reversed() {
                            parseStack.push(.symbol(symbol))
                        }
                        // `contextStack`'s entry for `nt` is popped by the
                        // matching `.reduce` above once it fires.
                    } else {
                        // No production's FIRST/FOLLOW covers the
                        // lookahead: panic-mode resynchronization. Skip
                        // input tokens until one is found that lets us
                        // either retry `nt`'s prediction, or treat `nt` as
                        // having matched nothing.
                        let expectedTerminals = Set(expected(nt).compactMap { $0.terminal }.filter { !$0.isEmpty })
                        var lookahead = (try? cursor.peek()) ?? (.meta(.eof), nil)

                        diagnostics.append(SyntaxError(
                            reason: .noViableAlternative,
                            message: "Unexpected \(lookahead.terminal) while parsing \(nt.name). Expected one of: \(expectedTerminals.map(\.description).sorted().joined(separator: ", ")).",
                            range: lookahead.range,
                            context: contextStack,
                            expected: Array(expectedTerminals),
                            found: lookahead.terminal,
                            source: stream.source))

                        var resynced = false
                        while lookahead.terminal != .meta(.eof) {
                            if lookaheadMatchesFirst(of: nt, lookahead: lookahead.terminal) {
                                resynced = true
                                break
                            }
                            if lookaheadMatchesFollow(of: nt, lookahead: lookahead.terminal) {
                                break
                            }
                            cursor.advance()
                            lookahead = (try? cursor.peek()) ?? (.meta(.eof), nil)
                        }

                        if resynced {
                            // Lookahead is now in FIRST(nt): retry.
                            parseStack.push(.symbol(predictedSymbol))
                            contextStack.removeLast()
                            continue
                        } else if lookaheadMatchesFollow(of: nt, lookahead: lookahead.terminal) {
                            // Lookahead is in FOLLOW(nt) (possibly because
                            // it's end-of-input, which always implicitly
                            // qualifies): treat `nt` as having matched
                            // nothing and resume with its parent's
                            // remaining symbols.
                            resultStack.append(.empty)
                            contextStack.removeLast()
                        } else {
                            // Ran out of input without ever finding a
                            // synchronizing token: unrecoverable.
                            diagnostics.append(SyntaxError(
                                reason: .prematureEndOfInput,
                                message: "Unexpected end of input while parsing \(nt.name).",
                                range: nil,
                                context: contextStack,
                                source: stream.source))
                            break parseLoop
                        }
                    }
                }
            }
        }

        return finalTree ?? resultStack.last
    }

    /// Returns `true` if `lookahead` matches some non-epsilon terminal in
    /// FIRST(`nonTerminal`).
    private func lookaheadMatchesFirst(of nonTerminal: NonTerminal, lookahead: Terminal) -> Bool {
        guard let firstSet = first[.nonTerminal(nonTerminal)] else { return false }
        return firstSet.contains { symbol in
            guard symbol != eps, case .terminal(let pattern) = symbol else { return false }
            return pattern.matches(lookahead)
        }
    }

    /// Returns `true` if `lookahead` matches some terminal in
    /// FOLLOW(`nonTerminal`).
    private func lookaheadMatchesFollow(of nonTerminal: NonTerminal, lookahead: Terminal) -> Bool {
        guard let followSet = follow[nonTerminal] else { return false }
        return followSet.contains { symbol in
            guard case .terminal(let pattern) = symbol else { return false }
            return pattern.matches(lookahead)
        }
    }

    private func predict<S: TokenStream>(A: NonTerminal, cursor: StreamCursor<S>) throws -> Production? {
        guard let productions = groupedProductions[A] else { return nil }
        let (terminal, _) = try cursor.peek()
        var prediction: Production?

        for production in productions {
            let firstSet = grammar.first(of: production.rule, using: self.first)
            
            guard let followA = follow[A] else { continue }

            Logger.ll.trace("Prediction for \(A) with current token: \(terminal).")

            // Check if current token is in First(Rule).
            //
            // firstSet holds grammar terminals (possibly regex/range/list
            // terminals resolved from a `lexical { }` declaration); `terminal`
            // is the concrete lexeme the cursor produced. Set.contains(_:) is
            // hash-based and would look up the wrong bucket for e.g. a
            // .regularExpression grammar terminal against a .string token (they
            // legitimately hash differently now that == is strict structural
            // equality - see Terminal.matches(_:) in the Grammar package), so
            // this has to scan and ask matches(_:) explicitly rather than call
            // Set.contains(.terminal(terminal)) directly.
            let matchFirst = firstSet.contains { symbol in
                guard case .terminal(let pattern) = symbol else { return false }
                return pattern.matches(terminal)
            }

            // Check if Rule is Nullable AND current token is in Follow(A)
            let matchFollow = firstSet.contains(eps) && followA.contains { symbol in
                guard case .terminal(let pattern) = symbol else { return false }
                return pattern.matches(terminal)
            }
            
            if matchFirst || matchFollow {
                if prediction != nil {
                    Logger.ll.warning("LL(1) conflict \(prediction!) vs \(production)")
                }
                if prediction == nil {
                    prediction = production
                }
            }
        }
        if let prediction {
            Logger.ll.trace("Production \(prediction) predicted from nonterminal: \(A) and look-ahead \(terminal).")
        }
        return prediction
    }
    
    
    /// Computes the terminals matching a nonterminal.
    private func expected(_ A: NonTerminal) -> Set<Symbol> {
        guard var expected = first[.nonTerminal(A)] else { return [] }
        if expected.contains(eps) {
            expected.formUnion(follow[A] ?? [])
        }
        return expected
    }
}

/// A one-token-lookahead cursor over a `TokenStream`, used by the LL(1)
/// algorithm above in place of GrammarTokenizer's `ParserInput`.
///
/// LL(1) only ever reads the input strictly left-to-right, one token of
/// lookahead at a time, so a `TokenStream`'s random-access `terminal(at:)`
/// is used here purely as an indexed pull — `peek()`/`advance()` never
/// revisit a past position.
///
/// Once the stream is exhausted (`position >= stream.count`), or a
/// `Terminal.meta(.eof)` is encountered before that point (some
/// `TokenStream` front ends include an explicit end-of-input entry, others
/// don't — see `Lexer`'s `TokenizerStream`), `peek()` keeps returning
/// `Terminal.meta(.eof)` with a `nil` range indefinitely.
private struct StreamCursor<S: TokenStream> {
    let stream: S
    private(set) var position = 0

    init(stream: S) { self.stream = stream }

    func peek() throws -> (terminal: Terminal, range: Range<String.Index>?) {
        guard position < stream.count else { return (.meta(.eof), nil) }
        let (terminal, range) = try stream.terminal(at: position)
        if case .meta(.eof) = terminal { return (.meta(.eof), nil) }
        return (terminal, range)
    }

    /// Looks `ahead` positions past the current one without advancing, and
    /// without throwing: a lexical error at the look-ahead position (or
    /// running past the end of the stream) is reported as the ordinary EOF
    /// sentinel rather than propagated. This is only ever used to make a
    /// recovery heuristic's decision (see `LLParser.parseWithRecovery`),
    /// never to actually consume that token, so silently treating a
    /// problem two tokens away as "nothing useful here" is the right
    /// trade-off — the main loop's own `peek()` will surface the real
    /// error properly once the cursor actually reaches that position.
    func peek(ahead: Int) -> (terminal: Terminal, range: Range<String.Index>?) {
        let targetPosition = position + ahead
        guard targetPosition < stream.count, let result = try? stream.terminal(at: targetPosition) else {
            return (.meta(.eof), nil)
        }
        if case .meta(.eof) = result.terminal { return (.meta(.eof), nil) }
        return result
    }

    mutating func advance() {
        if position < stream.count { position += 1 }
    }
}
