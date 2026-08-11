import Foundation

// MARK: - FallbackSearchProvider

/// Tries several search providers in order and returns the first non-empty result set.
///
/// An empty result set counts as a failure and moves on, so a query with genuinely no hits costs
/// one call to every provider before it throws.
///
/// ## Example
///
/// ```swift
/// let provider = FallbackSearchProvider(providers: [
///     BraveSearchProvider(apiKey: "BRAVE_KEY"),
///     SerperSearchProvider(apiKey: "SERPER_KEY")
/// ])
/// let results = try await provider.search(query: "Swift", maxResults: 5)
/// ```
public final class FallbackSearchProvider: WebSearchProvider, @unchecked Sendable {
    // MARK: - Properties

    private let providers: [any WebSearchProvider]

    // MARK: - Initialization

    /// Creates a chain.
    ///
    /// - Parameter providers: Providers in the order they should be tried.
    public init(providers: [any WebSearchProvider]) {
        self.providers = providers
    }

    // MARK: - WebSearchProvider

    /// Tries each provider in turn until one returns results.
    ///
    /// - Throws: `WebSearchError.allProvidersFailed`, carrying one error per provider — including a
    ///   `noResults` entry for each provider that answered with an empty list.
    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        var errors: [Error] = []

        for provider in providers {
            do {
                let results = try await provider.search(query: query, maxResults: maxResults)
                if !results.isEmpty {
                    return results
                }
                // Empty results — try next provider
                errors.append(WebSearchError.noResults)
            } catch {
                errors.append(error)
            }
        }

        throw WebSearchError.allProvidersFailed(errors)
    }
}
