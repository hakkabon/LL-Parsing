//
//  GrammarLogger.swift
//  LL-Parsing
//
//  Created by Ulf Akerstedt-Inoue on 2025/09/21.
//  Copyright © 2025 hakkabon software. All rights reserved.
//

#if canImport(OSLog)
import OSLog
#endif

/// Keeps diagnostics optional and the parsing product portable to platforms
/// where Apple's unified logging module is unavailable.
enum LLParserLog {
    #if canImport(OSLog)
    private static let logger = Logger(
        subsystem: "com.grammar.hakkabon", category: "LL(1)"
    )

    static func trace(_ message: @autoclosure () -> String) {
        let rendered = message()
        logger.trace("\(rendered, privacy: .public)")
    }

    static func warning(_ message: @autoclosure () -> String) {
        let rendered = message()
        logger.warning("\(rendered, privacy: .public)")
    }
    #else
    static func trace(_ message: @autoclosure () -> String) {}
    static func warning(_ message: @autoclosure () -> String) {}
    #endif
}
