import Foundation

// MARK: - WebSearchProvider Protocol

/// A search backend the tool kit can call.
///
/// Implement it to plug in an engine this package does not ship. Implementations are expected to
/// throw `WebSearchError` and to honour `maxResults`; neither is enforced.
///
/// ## Example
///
/// ```swift
/// let provider = SerperSearchProvider(apiKey: "YOUR_API_KEY", gl: "jp", hl: "ja")
/// let results = try await provider.search(query: "Swift concurrency", maxResults: 5)
/// ```
public protocol WebSearchProvider: Sendable {
    /// Runs one query.
    ///
    /// - Parameters:
    ///   - query: Query string, passed to the engine unmodified.
    ///   - maxResults: Upper bound on results; providers clamp it to their own API limit.
    /// - Returns: Results in the engine's ranking order.
    func search(query: String, maxResults: Int) async throws -> [WebSearchResult]
}

// MARK: - WebSearchResult

/// One search hit, as the engine ranked it.
///
/// `date` and `position` are carried through when a provider reports them, since freshness and
/// rank are how a reader judges a source. `BraveSearchProvider` reports neither, so results from
/// it always leave both `nil`.
public struct WebSearchResult: Codable, Sendable {
    public let title: String

    public let url: String

    public let snippet: String

    /// Publication date as the provider spelled it; unparsed, and formatted differently per engine.
    public let date: String?

    /// Rank in the result list, 1-based; `nil` when the provider reports no rank.
    public let position: Int?

    public init(title: String, url: String, snippet: String, date: String? = nil, position: Int? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.date = date
        self.position = position
    }
}

// MARK: - UnconfiguredSearchProvider

/// Stand-in provider whose every search fails with instructions for configuring a real one.
///
/// Lets a host wire search up before it has an API key, turning the missing key into a runtime
/// message instead of a build error. The tool kit does not use it: passing `nil` there drops the
/// `web_search` tool entirely, which is usually what you want.
public struct UnconfiguredSearchProvider: WebSearchProvider {
    public init() {}

    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        throw WebSearchError.providerNotConfigured
    }
}

// MARK: - Errors

/// Failures raised by search providers and by the resilience wrappers around them.
///
/// Messages are addressed to the model, so a failed search suggests rephrasing or waiting rather
/// than ending the task.
public enum WebSearchError: Error, LocalizedError {
    case invalidQuery(String)
    case invalidResponse
    case httpError(statusCode: Int)
    case encodingError
    case noResults
    case providerNotConfigured
    case circuitBreakerOpen
    case allProvidersFailed([Error])

    public var errorDescription: String? {
        switch self {
        case .invalidQuery(let query):
            return "Invalid search query: \(query). Try rephrasing your query."
        case .invalidResponse:
            return "Search engine returned an invalid response. Try again or rephrase your query."
        case .httpError(let statusCode):
            switch statusCode {
            case 429:
                return "Search rate limited (HTTP 429). Wait before retrying."
            case 403:
                return "Search access blocked (HTTP 403). Try again later."
            default:
                return "Search failed with HTTP \(statusCode). Try again or rephrase your query."
            }
        case .encodingError:
            return "Cannot decode the search results. Try again."
        case .noResults:
            return "No results found. Try different keywords or a broader query."
        case .providerNotConfigured:
            return "No search provider configured. Inject a WebSearchProvider (e.g. SerperSearchProvider) into ResearchToolKit."
        case .circuitBreakerOpen:
            return "Search provider is temporarily unavailable due to repeated failures. Try again later."
        case .allProvidersFailed(let errors):
            let descriptions = errors.map { $0.localizedDescription }.joined(separator: "; ")
            return "All search providers failed: \(descriptions)"
        }
    }
}
