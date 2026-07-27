//
//  DiagnosticReporter.swift
//  LL-Parsing
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/27.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation
import TerminalColors

/// Pretty-prints a batch of `SyntaxError`s in a style modeled on `rustc`: a
/// bold error title, the 1-based source location, the offending source
/// line, and a squiggly underline beneath the exact token range.
///
/// This mirrors the `Grammar` package's `GrammarParser`/`DiagnosticReporter`
/// pair (see that package's `GrammarDiagnostics.swift`), which reports
/// errors found while parsing a grammar *definition*. This type reports
/// errors found while parsing *input written in* a grammar, collected by
/// `LLParser.parseWithRecovery(_:)`.
public struct DiagnosticReporter {

    private let errorTitle = TerminalColor(fg: .red, .bold, .reversed)
    private let messageStyle = TerminalColor(.bold)
    private let metaColor = TerminalColor(fg: .blue)
    private let squiggleColor = TerminalColor(fg: .red)

    public init() {}

    /// Prints every diagnostic in `diagnostics` to standard output, each
    /// with its own gutter/underline context. Does nothing if `diagnostics`
    /// is empty.
    public func report(diagnostics: [SyntaxError]) {
        guard !diagnostics.isEmpty else { return }
        print(string(for: diagnostics))
    }

    /// Renders every diagnostic in `diagnostics` without printing it — e.g.
    /// to write the report to a file, or collect it for a test assertion,
    /// instead of sending it to stdout.
    public func string(for diagnostics: [SyntaxError]) -> String {
        guard !diagnostics.isEmpty else { return "" }
        let count = diagnostics.count
        let title = "Found \(count) \(count == 1 ? "error" : "errors"):"
        let header = "\n\(title, color: errorTitle)\n"
        let blocks = diagnostics.enumerated()
            .map { index, error in block(for: error, index: index + 1) }
            .joined(separator: "\n\n")
        return header + "\n" + blocks
    }

    /// Renders a single diagnostic's block, e.g. for collecting into a
    /// larger report rather than printing directly.
    public func block(for error: SyntaxError, index: Int) -> String {
        let sourceLines = error.source.components(separatedBy: .newlines)
        let lineIndex = error.line - 1

        guard sourceLines.indices.contains(lineIndex) else {
            // Should only happen for a pathological `source`/`range` pairing
            // (e.g. a `SyntaxError` built by hand against the wrong source);
            // fall back to a plain one-line report rather than trapping.
            return "[\(index)] \(error)"
        }

        let lineContent = sourceLines[lineIndex]

        let tokenLength: Int = {
            guard let range = error.range else { return 1 }
            return max(1, error.source.distance(from: range.lowerBound, to: range.upperBound))
        }()

        let padding = String(repeating: " ", count: max(0, error.column - 1))
        let squiggles = String(repeating: "^", count: tokenLength)
        let underline = "\(padding)\(squiggles, color: squiggleColor)"

        let lineLabel = String(format: "%3d |", error.line)
        let gutter = "\(lineLabel, color: metaColor)"
        let emptyGutter = "\("    |", color: metaColor)"
        let arrow = "\("-->", color: metaColor)"

        return """
        \("[\(index)] \(error.message)", color: messageStyle)
           \(arrow) Line \(error.line):\(error.column)
           \(emptyGutter)
           \(gutter) \(lineContent)
           \(emptyGutter) \(underline)
        """
    }
}
