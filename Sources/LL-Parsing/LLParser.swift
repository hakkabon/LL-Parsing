//
//  LLParser.swift
//  Grammar
//
//  Created by Ulf Akerstedt-Inoue on 2025/10/26.
//  Copyright © 2025 hakkabon software. All rights reserved.
//

import Foundation
import Grammar
import Lexer
import OSLog

enum ParseError: Error {
    case runtimeError(String)
    case tokenError(String)
    case noTokenError(String)
}

public class LLParser: Parser {
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
                    // Return the root of the tree (should be the only item left)
                    return resultStack.removeFirst()
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

    mutating func advance() {
        if position < stream.count { position += 1 }
    }
}
