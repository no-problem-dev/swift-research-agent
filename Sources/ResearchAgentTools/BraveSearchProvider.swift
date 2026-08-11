import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - BraveSearchProvider

/// Search provider backed by the Brave Search REST API.
///
/// Needs a Brave Search API key. Results carry no date and no rank, so sources found this way lose
/// the freshness and ranking signals a Serper result would keep.
///
/// ## Example
///
/// ```swift
/// let provider = BraveSearchProvider(apiKey: "YOUR_API_KEY")
/// let results = try await provider.search(query: "Swift concurrency", maxResults: 5)
/// ```
public final class BraveSearchProvider: WebSearchProvider, @unchecked Sendable {
    // MARK: - Properties

    private let apiKey: String
    private let searchLang: String?
    private let country: String?
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    // MARK: - Initialization

    /// Creates a Brave-backed provider.
    ///
    /// - Parameters:
    ///   - apiKey: Brave Search API key.
    ///   - searchLang: Search language, for example "ja".
    ///   - country: Country code, for example "JP".
    ///   - timeout: Per-request timeout in seconds (default: 15).
    ///   - transport: HTTP transport, for substituting one in tests.
    public init(
        apiKey: String,
        searchLang: String? = nil,
        country: String? = nil,
        timeout: TimeInterval = 15,
        transport: (any HTTPTransport)? = nil
    ) {
        self.apiKey = apiKey
        self.searchLang = searchLang
        self.country = country
        self.timeout = timeout
        if let transport {
            self.transport = transport
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout * 2
            self.transport = URLSessionTransport(session: URLSession(configuration: config), defaultTimeout: timeout)
        }
    }

    // MARK: - WebSearchProvider

    /// Runs one query against Brave Search.
    ///
    /// This provider does not retry: a non-2xx status throws immediately. Wrap it in
    /// `ResilientSearchProvider` if you want retries, a rate limit or a circuit breaker.
    ///
    /// - Parameters:
    ///   - query: Query string.
    ///   - maxResults: Upper bound on results, clamped to Brave's limit of 20.
    /// - Throws: `WebSearchError.invalidQuery` if the query cannot be put in a URL, or
    ///   `WebSearchError.httpError` for a non-2xx response.
    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(min(maxResults, 20)))
        ]
        if let searchLang {
            queryItems.append(URLQueryItem(name: "search_lang", value: searchLang))
        }
        if let country {
            queryItems.append(URLQueryItem(name: "country", value: country))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw WebSearchError.invalidQuery(query)
        }

        let request = HTTPRequest(
            method: "GET",
            url: url,
            headers: ["X-Subscription-Token": apiKey, "Accept": "application/json"],
            timeout: timeout
        )

        let response = try await transport.send(request)

        guard (200...299).contains(response.status) else {
            throw WebSearchError.httpError(statusCode: response.status)
        }

        let braveResponse = try JSONDecoder().decode(BraveSearchResponse.self, from: response.body)

        return (braveResponse.web?.results ?? []).prefix(maxResults).map { result in
            WebSearchResult(
                title: result.title,
                url: result.url,
                snippet: result.description ?? ""
            )
        }
    }
}

// MARK: - Brave API Response Types

private struct BraveSearchResponse: Decodable {
    let web: BraveWebResults?
}

private struct BraveWebResults: Decodable {
    let results: [BraveWebResult]
}

private struct BraveWebResult: Decodable {
    let title: String
    let url: String
    let description: String?
}
