//
//  SyntaxError.swift
//  LL-Parsing
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/27.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation
import Grammar

/// A single syntax error encountered — and, where possible, recovered from —
/// while parsing with `LLParser`.
///
/// `LLParser.parse(_:)` / `syntaxTree(for:)` are unchanged: they still throw
/// a `ParseError` and stop at the very first problem. `SyntaxError` is
/// instead what `LLParser.parseWithRecovery(_:)` collects: that entry point
/// keeps going after a mistake using panic-mode recovery (see the "Error
/// Recovery" section of the README, or `LLParser.parseWithRecovery` itself
/// for the algorithm), so a single pass can surface more than one mistake.
///
/// This intentionally mirrors the shape of the `Grammar` package's own
/// `GrammarParser`/`ParserDiagnostic` pair (see that package's
/// `GrammarDiagnostics.swift`), which reports errors found while parsing a
/// *grammar definition* itself. `SyntaxError` is the same idea one level up:
/// errors found while parsing *input written in* a grammar.
public struct SyntaxError: Error {

    /// What kind of problem was detected.
    public enum Reason: Equatable {
        /// The item on top of the parse stack was a terminal that did not
        /// match the current input token, and recovery assumed the token
        /// was simply missing: it proceeded as though the terminal had
        /// been inserted, without consuming any input. This is the
        /// classic "insertion" recovery for predictive parsers.
        case missingToken

        /// The item on top of the parse stack was a terminal that did not
        /// match the current input token, and recovery instead discarded
        /// one or more input tokens (a "deletion") before resuming,
        /// because doing so let the very next token match.
        case extraToken

        /// A non-terminal on top of the stack had no production whose
        /// FIRST (or, for a nullable production, FOLLOW) set contained
        /// the current lookahead token. Recovery skipped input tokens
        /// until a synchronizing token was found.
        case noViableAlternative

        /// The underlying token stream reported a lexical error (e.g. an
        /// unrecognized character) at the current position.
        case invalidToken

        /// Input ended while the parser still expected more tokens, and
        /// no synchronizing token could be found to resume from. Unlike
        /// the other cases, this one is not recovered from — parsing
        /// stops here.
        case prematureEndOfInput

        /// A production explicitly requires a non-empty derivation at
        /// this point, but nothing could be derived. Reserved for callers
        /// building `SyntaxError` values outside `LLParser` itself.
        case emptyNotAllowed

        /// A token could not be classified as any terminal the grammar
        /// knows about. Reserved for callers building `SyntaxError`
        /// values outside `LLParser` itself.
        case unknownToken

        /// A pattern-typed terminal (e.g. from a `lexical { }` block)
        /// could not be resolved against any concrete lexed token.
        /// Reserved for callers building `SyntaxError` values outside
        /// `LLParser` itself.
        case unmatchedPattern

        /// Catch-all for a token that could not legally appear at this
        /// point, when none of the more specific reasons above apply.
        case unexpectedToken
    }

    /// The range of source text this error is anchored to. `nil` when the
    /// error was detected at the true end of input, where there is no
    /// token left to point at.
    public let range: Range<String.Index>?

    /// What kind of problem this is.
    public let reason: Reason

    /// A human-readable explanation, already filled in with the specific
    /// symbols involved (e.g. `"Expected ')', but found '+'."`).
    public let message: String

    /// The chain of non-terminals being expanded when the error was
    /// detected, outermost first (e.g. `[Expr, Term]`). Empty if unknown.
    public let context: [NonTerminal]

    /// The terminals that would have been acceptable at this point, if
    /// known — e.g. FIRST(A) ∪ FOLLOW(A) for a failed non-terminal
    /// prediction, or the single expected terminal for a terminal
    /// mismatch.
    public let expected: [Terminal]

    /// The concrete terminal actually found at `range`, if any.
    public let found: Terminal?

    /// The full source text that `range` (when non-`nil`) is a substring
    /// of. Kept on the error itself so it is self-contained and can be
    /// pretty-printed by `DiagnosticReporter` without separately
    /// threading the original string through every call site.
    public let source: String

    /// 1-based line number of `range`'s start (or, if `range` is `nil`,
    /// of the very end of `source`).
    public let line: Int

    /// 1-based column number of `range`'s start (or, if `range` is `nil`,
    /// of the very end of `source`).
    public let column: Int

    public init(
        reason: Reason,
        message: String,
        range: Range<String.Index>?,
        context: [NonTerminal] = [],
        expected: [Terminal] = [],
        found: Terminal? = nil,
        source: String
    ) {
        self.reason = reason
        self.message = message
        self.range = range
        self.context = context
        self.expected = expected
        self.found = found
        self.source = source
        let (line, column) = source.lineAndColumn(at: range?.lowerBound ?? source.endIndex)
        self.line = line
        self.column = column
    }
}

extension SyntaxError: CustomStringConvertible {
    public var description: String {
        "[\(line):\(column)] Error: \(message)"
    }
}

extension String {
    /// Computes the 1-based line and column of `index` within this string.
    ///
    /// Column counts `Character`s (extended grapheme clusters), matching
    /// how `Range<String.Index>` is used everywhere else in this package.
    /// This is `O(n)` in the distance from the start of the string, which
    /// is fine here: it only runs once per diagnostic, not once per token.
    func lineAndColumn(at index: String.Index) -> (line: Int, column: Int) {
        var line = 1
        var column = 1
        var cursor = startIndex
        while cursor < index && cursor < endIndex {
            if self[cursor] == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
            cursor = self.index(after: cursor)
        }
        return (line, column)
    }
}
