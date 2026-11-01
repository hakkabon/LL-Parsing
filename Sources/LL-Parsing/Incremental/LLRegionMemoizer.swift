/// A stable, positioned token used to prove that an LL parse region is
/// unchanged across source revisions.
public protocol LLRegionToken: Sendable {
    associatedtype ID: Hashable & Sendable
    var regionTokenID: ID { get }
    var regionSourceOffset: Int { get }
}

/// Cached syntax or parser evidence that moves uniformly with a reused region.
public protocol LLRegionRelocatable: Sendable {
    func relocated(by delta: Int) -> Self
}

/// Recovery evidence may refer to deleted tokens. When those tokens still
/// exist in the current stream, replay should use the current token values.
public protocol LLRegionRecovery: Sendable {
    associatedtype Token: LLRegionToken
    func relocated(by delta: Int,
                   currentTokens: [Token.ID: Token]) -> Self
}

public struct LLRegionEffects<Diagnostic: LLRegionRelocatable,
                              Recovery: LLRegionRecovery,
                              Expectation: LLRegionRelocatable>: Sendable {
    public let diagnostics: [Diagnostic]
    public let recoveries: [Recovery]
    public let expectations: [Expectation]

    public init(diagnostics: [Diagnostic], recoveries: [Recovery],
                expectations: [Expectation]) {
        self.diagnostics = diagnostics
        self.recoveries = recoveries
        self.expectations = expectations
    }
}

public struct LLRegionCache<Rule: Hashable & Sendable,
                            Token: LLRegionToken,
                            Node: LLRegionRelocatable,
                            Diagnostic: LLRegionRelocatable,
                            Recovery: LLRegionRecovery,
                            Expectation: LLRegionRelocatable>: Sendable
where Recovery.Token == Token {
    public struct Key: Hashable, Sendable {
        public let rule: Rule
        public let startTokenID: Token.ID

        public init(rule: Rule, startTokenID: Token.ID) {
            self.rule = rule
            self.startTokenID = startTokenID
        }
    }

    public struct Entry: Sendable {
        public let tokenIDs: [Token.ID]
        public let tokenRelativeLocations: [Int]
        public let nextTokenID: Token.ID
        public let nextTokenRelativeLocation: Int
        public let startLocation: Int
        public let node: Node
        public let effects: LLRegionEffects<Diagnostic, Recovery, Expectation>

        public init(tokenIDs: [Token.ID], tokenRelativeLocations: [Int],
                    nextTokenID: Token.ID, nextTokenRelativeLocation: Int,
                    startLocation: Int, node: Node,
                    effects: LLRegionEffects<Diagnostic, Recovery, Expectation>) {
            self.tokenIDs = tokenIDs
            self.tokenRelativeLocations = tokenRelativeLocations
            self.nextTokenID = nextTokenID
            self.nextTokenRelativeLocation = nextTokenRelativeLocation
            self.startLocation = startLocation
            self.node = node
            self.effects = effects
        }
    }

    public fileprivate(set) var entries: [Key: Entry]

    public init(entries: [Key: Entry] = [:]) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }
}

public struct LLRegionReuse<Node: LLRegionRelocatable,
                            Diagnostic: LLRegionRelocatable,
                            Recovery: LLRegionRecovery,
                            Expectation: LLRegionRelocatable>: Sendable {
    public let node: Node
    public let consumedTokenCount: Int
    public let effects: LLRegionEffects<Diagnostic, Recovery, Expectation>
}

/// Owns identity proof, lookahead validation, nested-cache preservation, and
/// recovery replay for one incremental LL parse run.
public struct LLRegionMemoizer<Rule: Hashable & Sendable,
                               Token: LLRegionToken,
                               Node: LLRegionRelocatable,
                               Diagnostic: LLRegionRelocatable,
                               Recovery: LLRegionRecovery,
                               Expectation: LLRegionRelocatable>: Sendable
where Recovery.Token == Token {
    public typealias Cache = LLRegionCache<
        Rule, Token, Node, Diagnostic, Recovery, Expectation>

    private let previous: Cache?
    public private(set) var result = Cache()

    public init(previous: Cache? = nil) {
        self.previous = previous
    }

    public var isIncremental: Bool { previous?.isEmpty == false }

    public mutating func reuse(rule: Rule, tokens: [Token], at startIndex: Int)
        -> LLRegionReuse<Node, Diagnostic, Recovery, Expectation>? {
        guard tokens.indices.contains(startIndex) else { return nil }
        let startToken = tokens[startIndex]
        let key = Cache.Key(rule: rule, startTokenID: startToken.regionTokenID)
        guard let entry = previous?.entries[key],
              entryMatches(entry, tokens: tokens, at: startIndex) else {
            return nil
        }

        let delta = startToken.regionSourceOffset - entry.startLocation
        let endIndex = startIndex + entry.tokenIDs.count
        let currentTokens = Dictionary(uniqueKeysWithValues:
            tokens[startIndex..<endIndex].map { ($0.regionTokenID, $0) })
        let effects = relocate(
            entry.effects, by: delta, currentTokens: currentTokens)
        carryEntries(
            inside: entry, tokens: tokens, relocatingBy: delta)
        return LLRegionReuse(
            node: entry.node.relocated(by: delta),
            consumedTokenCount: entry.tokenIDs.count,
            effects: effects)
    }

    public mutating func record(rule: Rule, tokens: [Token],
                                startIndex: Int, endIndex: Int,
                                node: Node,
                                effects: LLRegionEffects<Diagnostic, Recovery, Expectation>) {
        guard tokens.indices.contains(startIndex),
              endIndex > startIndex, endIndex < tokens.count else { return }
        let startToken = tokens[startIndex]
        let consumed = tokens[startIndex..<endIndex]
        let key = Cache.Key(rule: rule, startTokenID: startToken.regionTokenID)
        result.entries[key] = Cache.Entry(
            tokenIDs: consumed.map(\.regionTokenID),
            tokenRelativeLocations: consumed.map {
                $0.regionSourceOffset - startToken.regionSourceOffset
            },
            nextTokenID: tokens[endIndex].regionTokenID,
            nextTokenRelativeLocation:
                tokens[endIndex].regionSourceOffset - startToken.regionSourceOffset,
            startLocation: startToken.regionSourceOffset,
            node: node,
            effects: effects)
    }

    private func entryMatches(_ entry: Cache.Entry,
                              tokens: [Token], at startIndex: Int) -> Bool {
        let endIndex = startIndex + entry.tokenIDs.count
        guard endIndex < tokens.count else { return false }
        let startLocation = tokens[startIndex].regionSourceOffset
        for (offset, tokenID) in entry.tokenIDs.enumerated() {
            let token = tokens[startIndex + offset]
            guard token.regionTokenID == tokenID,
                  token.regionSourceOffset - startLocation
                    == entry.tokenRelativeLocations[offset] else {
                return false
            }
        }
        return tokens[endIndex].regionTokenID == entry.nextTokenID
            && tokens[endIndex].regionSourceOffset - startLocation
                == entry.nextTokenRelativeLocation
    }

    private mutating func carryEntries(inside reusedEntry: Cache.Entry,
                                       tokens: [Token], relocatingBy delta: Int) {
        guard let previous else { return }
        let regionTokenIDs = Set(reusedEntry.tokenIDs)
        let currentTokens = Dictionary(uniqueKeysWithValues:
            tokens.map { ($0.regionTokenID, $0) })
        for (key, entry) in previous.entries
        where regionTokenIDs.contains(key.startTokenID) {
            let tokensAreInside = entry.tokenIDs.allSatisfy(regionTokenIDs.contains)
            let lookaheadIsInside = regionTokenIDs.contains(entry.nextTokenID)
                || entry.nextTokenID == reusedEntry.nextTokenID
            guard tokensAreInside, lookaheadIsInside else { continue }
            result.entries[key] = Cache.Entry(
                tokenIDs: entry.tokenIDs,
                tokenRelativeLocations: entry.tokenRelativeLocations,
                nextTokenID: entry.nextTokenID,
                nextTokenRelativeLocation: entry.nextTokenRelativeLocation,
                startLocation: entry.startLocation + delta,
                node: entry.node.relocated(by: delta),
                effects: relocate(
                    entry.effects, by: delta, currentTokens: currentTokens))
        }
    }

    private func relocate(
        _ effects: LLRegionEffects<Diagnostic, Recovery, Expectation>,
        by delta: Int, currentTokens: [Token.ID: Token]
    ) -> LLRegionEffects<Diagnostic, Recovery, Expectation> {
        LLRegionEffects(
            diagnostics: effects.diagnostics.map { $0.relocated(by: delta) },
            recoveries: effects.recoveries.map {
                $0.relocated(by: delta, currentTokens: currentTokens)
            },
            expectations: effects.expectations.map { $0.relocated(by: delta) })
    }
}
