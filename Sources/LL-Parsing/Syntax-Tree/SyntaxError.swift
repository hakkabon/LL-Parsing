//
//  SyntaxError.swift
//  GrammarParsing
//
//  Created by Ulf Akerstedt-Inoue on 2023/09/06.
//  Copyright © 2023 hakkabon software. All rights reserved.
//

import Foundation
import Grammar
import os.log

/// A syntax error which was generated during parsing or tokenization
public struct SyntaxError: Error {
    
    /// The reason for the syntax error
    ///
    /// - emptyNotAllowed: An empty string was provided but the grammar does not allow empty productions
    /// - unknownToken: The tokenization could not be completed because no matching token was found
    /// - unmatchedPattern: A pattern was found which could not be merged
    /// - unexpectedToken: A token was found that was not expected
    public enum Reason {
        /// An empty string was provided but the grammar does not allow empty productions
        case emptyNotAllowed
        
        /// The tokenization could not be completed because no matching token was found
        case unknownToken
        
        /// A pattern was found which could not be merged
        case unmatchedPattern
        
        /// A token was found that was not expected
        case unexpectedToken
    }
    
    /// Range in which the error occurred
    public let range: Range<String.Index>
    
    /// Reason for the error
    public let reason: Reason
    
    /// The context around the error
    public let context: [NonTerminal]
    
    /// The string for which the parsing was unsuccessful.
    public let string: String
    
    /// The line in which the error occurred.
    ///
    /// The first line of the input string is line 0.
    public var line: Int {
        if string.count == 0 {
            return 0
        }
        return string[...range.lowerBound].filter { (char: Character) in
            char.isNewline
        }.count
    }
    
    public var column: Int {
        if string.count == 0 {
            return 0
        }
        let lastNewlineIndex = string[...range.lowerBound].lastIndex(where: {$0.isNewline}) ?? string.startIndex
        return string.distance(from: lastNewlineIndex, to: range.lowerBound)
    }
    
    /// Creates a new syntax error with a given range and reason
    ///
    /// - Parameters:
    ///   - range: String range in which the syntax error occurred
    ///   - string: String which was unsuccessfully parsed
    ///   - reason: Reason why the syntax error occurred
    ///   - context: Non-terminals which were expected at the location of the error.
    public init(range: Range<String.Index>, in string: String, reason: Reason, context: [NonTerminal] = []) {
        self.range = range
        self.string = string
        self.reason = reason
        self.context = context
    }
}

extension SyntaxError: CustomStringConvertible {
    public var description: String {
        let main = "Error: \(reason) at L\(line+1):\(column+1): '\(string[range])'"
        if !context.isEmpty {
            return "\(main), expected: \(context.map{$0.description}.joined(separator: " | "))"
        } else {
            return main
        }
    }
}

extension SyntaxError.Reason: CustomStringConvertible {
    public var description: String {
        switch self {
        case .emptyNotAllowed:
            return "Empty string not accepted"
        case .unknownToken:
            return "Unknown token"
        case .unmatchedPattern:
            return "Unmatched pattern"
        case .unexpectedToken:
            return "Unexpected token"
        }
    }
}

