//
//  Parse.swift
//  GrammarParse
//
//  Created by Ulf Akerstedt-Inoue on 2024/03/16.
//  Copyright © 2024 hakkabon software. All rights reserved.
//

import Foundation
import ArgumentParser
import Grammar
import LL_Parsing
import ShellOut

/// Parses any input sentence based on its given grammar specification.

extension GrammarTool {
    
    struct Parse: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Generate parse tree of input applied to given grammar.")

        @OptionGroup var options: Options

        @Option(name: [.short, .long], help: "Method to apply when parsing the input string.")
        var method: Method = Method.ll

        @Option(name: [.short, .long], help: "Input to be parsed using the grammar.", transform: Source.init)
        var input: Source = Source("")
        
        @Option(name: [.long, .short], help: "Use { tree | graph | sppf } to display result of parse.")
        var analysis: Analysis = .tree

        mutating func run() throws {
            
            let grammar: Grammar = switch Notation(argument: options.grammar.pathExtension) {
            case .bnf: try Grammar(bnf: try String(contentsOf: options.grammar), start: options.start)
            case .ebnf: try Grammar(ebnf: try String(contentsOf: options.grammar), start: options.start)
            case .gen: try Grammar(gen: try String(contentsOf: options.grammar))
            case .wsn: try Grammar(wsn: try String(contentsOf: options.grammar), start: options.start)
            case .custom(_):
                //TODO: not implemented yet!
                try Grammar(bnf: try String(contentsOf: options.grammar), start: options.start)
            }
            
            let parser: Parser = switch method {
            case .ll: LLParser(grammar: grammar)
            }
            
            switch input {
            case .arg(let inputString):
                guard !inputString.isEmpty else { return }
                try runAnalysis(analysis, parser: parser, input: inputString, grammar: grammar)
                
            case .url(let url):
                let content = try String(contentsOf: url)
                try runAnalysis(analysis, parser: parser, input: content, grammar: grammar)
            }
        }
                
        private func runAnalysis(_ analysis: Analysis, parser: Parser, input: String, grammar: Grammar) throws {
            switch analysis {
            case .tree:
                let parsetree = try parser.syntaxTree(for: input).mapLeafs{ String(input[$0]) }
                print("\(parsetree)")
                
            case .graph:
                let parsetree = try parser.syntaxTree(for: input).mapLeafs { String(input[$0]) }
                let dotfile = parsetree.graphviz
                try shellOut(to: ["echo '\(dotfile)' | dot -Tpdf > parse-tree.pdf", "open parse-tree.pdf"])
            }
        }
    }
}
