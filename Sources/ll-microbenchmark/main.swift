import Foundation
import LL_Parsing
import Parser

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count <= 1 else {
        throw NSError(
            domain: "ll-microbenchmark", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "usage: ll-microbenchmark [output.json]"]
        )
    }
    #if DEBUG
    let configuration = ParserEngineMicrobenchmarkSuite.BuildConfiguration.debug
    #else
    let configuration = ParserEngineMicrobenchmarkSuite.BuildConfiguration.release
    #endif
    let report = try LLParserMicrobenchmarks.run(buildConfiguration: configuration)
    let data = try ParserEngineMicrobenchmarkCodec.encode(report)
    if let output = arguments.first {
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
} catch {
    FileHandle.standardError.write(Data("ll-microbenchmark: \(error)\n".utf8))
    exit(1)
}
