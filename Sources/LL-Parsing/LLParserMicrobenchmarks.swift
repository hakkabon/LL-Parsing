import Foundation
import Grammar
import Parser

/// Engine-owned executable microbenchmarks for the LL(1) implementation.
public enum LLParserMicrobenchmarks {
    public static let ownerVersion = "0.1.2"
    public static let inputScale = 24

    private static let grammarSource = """
    <E> ::= <T> <R>
    <R> ::= '+' <T> <R> | ε
    <T> ::= 'id'
    """

    private static var input: String {
        Array(repeating: "id", count: inputScale).joined(separator: " + ")
    }

    public static func suite(
        buildConfiguration: ParserEngineMicrobenchmarkSuite.BuildConfiguration,
        warmupIterations: Int = 2,
        measurementIterations: Int = 10
    ) -> ParserEngineMicrobenchmarkSuite {
        .init(
            owner: .init(repository: "LL-Parsing", version: ownerVersion),
            engineID: "ll1", id: "ll1-core-v1", title: "LL(1) core workloads",
            buildConfiguration: buildConfiguration,
            warmupIterations: warmupIterations,
            measurementIterations: measurementIterations,
            cases: [.init(
                id: "expression-parse", title: "Parse a right-recursive expression chain",
                operation: .parsing,
                boundary: "Tokenize and build one syntax tree with a pre-built LLParser.",
                workloadFingerprint: ParserEngineMicrobenchmarkCodec.evidenceFingerprint([
                    grammarSource, input, "prebuilt-parser", "syntax-tree"
                ]),
                scale: inputScale
            )]
        )
    }

    public static func run(
        buildConfiguration: ParserEngineMicrobenchmarkSuite.BuildConfiguration,
        warmupIterations: Int = 2,
        measurementIterations: Int = 10,
        environment: ParserEngineMicrobenchmarkEnvironment = .current
    ) throws -> ParserEngineMicrobenchmarkReport {
        let parser = LLParser(grammar: try Grammar(bnf: grammarSource, start: "E"))
        return try ParserEngineMicrobenchmarkRunner.run(
            suite(
                buildConfiguration: buildConfiguration,
                warmupIterations: warmupIterations,
                measurementIterations: measurementIterations
            ),
            environment: environment
        ) { _ in
            let tree = try parser.parse(input)
            let leaves = tree.leafs.count
            return .init(
                evidenceFingerprint: ParserEngineMicrobenchmarkCodec.evidenceFingerprint([
                    "accepted", String(leaves), String(inputScale)
                ]),
                counters: ["accepted": 1, "leafCount": leaves, "tokenCount": inputScale * 2 - 1]
            )
        }
    }
}
