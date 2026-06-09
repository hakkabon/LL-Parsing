//
//  LLParser.swift
//  Grammar
//
//  Created by Ulf Akerstedt-Inoue on 2025/10/26.
//  Copyright © 2025 hakkabon software. All rights reserved.
//

import Foundation
import Grammar
import Tokenizer
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

    /// Interprets a source character stream by using ther LL(1) parsing algorithm.
    public func parse(_ source: String) throws -> ParseTree {
        // set input source
        let it = Tokenizer(source, symbols: Set(symbols), keywords: Set(keywords))
        var tokenizer = ParserInput(it)
        
        // Initialize token stream
        var currentToken = tokenizer.get()
    
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
                    let (tokenTerminal, range) = try extractTerminal(currentToken)
                    guard terminal == tokenTerminal else {
                        throw ParseError.runtimeError("Expected \(terminal), but found token: \(currentToken.type).")
                    }
                    
                    Logger.ll.trace("Matched \(predictedSymbol) with current token \(currentToken.type).")
                    
                    // Create Leaf Node
                    resultStack.append(.leaf(range))
                    
                    // Advance Tokenizer
                    currentToken = tokenizer.get()
                }
                
                if case .nonTerminal(let nt) = predictedSymbol {
                    guard let production = try predict(A: nt, token: currentToken) else {
                        throw ParseError.runtimeError("Prediction not possible for \(nt) with current token: \(currentToken.type).")
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
 
    private func predict(A: NonTerminal, token: Token) throws -> Production? {
        guard let productions = groupedProductions[A] else { return nil }
        let (terminal, _) = try extractTerminal(token)
        var prediction: Production?

        for production in productions {
            let firstSet = grammar.first(of: production.rule, using: self.first)
            
            guard let followA = follow[A] else { continue }

            Logger.ll.trace("Prediction for \(A) with current token: \(token.type) → terminal: \(terminal).")

            // Check if current token is in First(Rule)
            let matchFirst = firstSet.contains(.terminal(terminal))
            
            // Check if Rule is Nullable AND current token is in Follow(A)
            let matchFollow = firstSet.contains(eps) && followA.contains(.terminal(terminal))
            
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
    
    /// Extracts the `Terminal` type contained in a given token.
    func extractTerminal(_ token: Token) throws -> (terminal: Terminal, range: Range<String.Index>) {
        let (terminal, range) = switch token.type {
        case .symbol(let symbol):
            (Terminal(string: symbol), token.range)
        case .literal(let literal):
            (Terminal(string: literal), token.range)
        case .identifier(let identifier):
            (Terminal(string: identifier), token.range)
        case .number(let number):
            switch number {
            case .decimal(let value), .binary(let value), .octal(let value), .hexadecimal(let value):
                (Terminal(string: "\(value)"), token.range)
            }
        case .eof:
            (.meta(.eof), token.range)
        default:
            throw ParseError.tokenError("symbol \(token) not recognized")
        }
        return (terminal, range)
    }
}
