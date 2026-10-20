import Testing
import Parser
@testable import LL_Parsing

@Test("LL owns a reproducible executable microbenchmark")
func llMicrobenchmark() throws {
    let report = try LLParserMicrobenchmarks.run(
        buildConfiguration: .release, warmupIterations: 0, measurementIterations: 3,
        environment: .init(
            operatingSystem: "test", architecture: "test",
            processorCount: 1, physicalMemoryBytes: 1
        )
    )
    #expect(report.suite.owner.repository == "LL-Parsing")
    #expect(report.suite.engineID == "ll1")
    #expect(report.results.first?.counters["accepted"] == 1)
    #expect(report.results.first?.counters["leafCount"] == LLParserMicrobenchmarks.inputScale * 2 - 1)
}
