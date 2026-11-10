import Parser

/// A cached token that can reconstruct its positioned value when no matching
/// stable token exists in the current stream.
public protocol LLRegionRelocatingToken: LLRegionToken {
    func relocatedRegionToken(by delta: Int) -> Self
}

/// Shared parser products are directly reusable by the LL region cache. The
/// conformance belongs beside the cache protocol, not in each language kit.
extension LanguageSyntaxNode: LLRegionRelocatable {}
extension LanguageParseDiagnostic: LLRegionRelocatable {}

extension LanguageParseExpectation: LLRegionRelocatable {
    public func relocated(by delta: Int) -> Self {
        Self(offset: offset + delta, kinds: kinds)
    }
}

extension LanguageRecoveryAction: LLRegionRecovery
where Token: LLRegionRelocatingToken {
    public func relocated(
        by delta: Int, currentTokens: [Token.ID: Token]
    ) -> Self {
        switch self {
        case let .insert(kind, offset):
            .insert(kind: kind, at: offset + delta)
        case let .delete(token):
            .delete(token: currentTokens[token.regionTokenID]
                ?? token.relocatedRegionToken(by: delta))
        }
    }
}
