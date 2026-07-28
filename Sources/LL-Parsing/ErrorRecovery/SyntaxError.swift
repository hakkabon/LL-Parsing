//
//  SyntaxError.swift
//  LL-Parsing
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/27.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Parser

/// Compatibility name for the parser-independent diagnostic model.
public typealias SyntaxError = ParseDiagnostic

/// Immutable result returned by LL error-recovering parses.
public typealias LLParseResult = UntracedParseResult
