import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - SerperSearchProvider

/// Search provider backed by the Serper REST API, which returns Google's result page.
///
/// Needs a Serper API key. Results keep the publication date and the rank Google reported, which
/// is what the ledger records alongside each source.
///
/// ## Example
///
/// ```swift
/// let provider = SerperSearchProvider(apiKey: "YOUR_API_KEY", gl: "jp", hl: "ja")
/// let results = try await provider.search(query: "Swift concurrency", maxResults: 5)
/// ```
public final class SerperSearchProvider: WebSearchProvider, @unchecked Sendable {
    // MARK: - Properties

    private let apiKey: String
    private let gl: String?
    private let hl: String?
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    // MARK: - Initialization

    /// Creates a Serper-backed provider.
    ///
    /// - Parameters:
    ///   - apiKey: Serper API key.
    ///   - gl: Region code, for example "jp".
    ///   - hl: Language code, for example "ja".
    ///   - timeout: Per-request timeout in seconds (default: 15).
    ///   - transport: HTTP transport, for substituting one in tests.
    public init(
        apiKey: String,
        gl: String? = nil,
        hl: String? = nil,
        timeout: TimeInterval = 15,
        transport: (any HTTPTransport)? = nil
    ) {
        self.apiKey = apiKey
        self.gl = gl
        self.hl = hl
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

    /// Runs one query against Serper.
    ///
    /// Only organic results are returned; answer boxes and ads are ignored. A result without a rank
    /// gets its position from the response order. This provider does not retry — wrap it in
    /// `ResilientSearchProvider` for that.
    ///
    /// - Parameters:
    ///   - query: Query string.
    ///   - maxResults: Upper bound on results, clamped to Serper's limit of 100.
    /// - Throws: `WebSearchError.httpError` for a non-2xx response.
    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        guard let url = URL(string: "https://google.serper.dev/search") else {
            throw WebSearchError.invalidResponse
        }

        let requestBody = SerperSearchRequest(q: query, num: min(maxResults, 100), gl: gl, hl: hl)
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: ["X-API-KEY": apiKey, "Content-Type": "application/json"],
            body: try JSONEncoder().encode(requestBody),
            timeout: timeout
        )

        let response = try await transport.send(request)

        guard (200...299).contains(response.status) else {
            throw WebSearchError.httpError(statusCode: response.status)
        }

        let serperResponse = try JSONDecoder().decode(SerperSearchResponse.self, from: response.body)

        return (serperResponse.organic ?? []).prefix(maxResults).enumerated().map { index, result in
            WebSearchResult(
                title: result.title,
                url: result.link,
                snippet: result.snippet ?? "",
                date: result.date,
                position: result.position ?? (index + 1)
            )
        }
    }
}

// MARK: - Serper API Request / Response Types

private struct SerperSearchRequest: Encodable {
    let q: String
    let num: Int
    let gl: String?
    let hl: String?
}

private struct SerperSearchResponse: Decodable {
    let organic: [SerperOrganicResult]?
}

private struct SerperOrganicResult: Decodable {
    let title: String
    let link: String
    let snippet: String?
    let date: String?
    let position: Int?
}
