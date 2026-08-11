import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient
import LLMTool
import ResearchStore

// MARK: - ResearchToolKit

/// Provides the `web_search` and `fetch` tools, and records everything they observe in the ledger.
///
/// Search hits are recorded as not-yet-fetched; a successful fetch stores the page's whole
/// extracted text and marks the URL citable. That bookkeeping is what makes the citation gate
/// possible, and it is all this type does about citations — judging violations belongs to the gate.
///
/// ## Example
///
/// ```swift
/// let registry = SourceRegistry()
/// let toolKit = ResearchToolKit(
///     registry: registry,
///     searchProvider: SerperSearchProvider(apiKey: key, gl: "jp", hl: "ja")
/// )
/// ```
///
/// ## Tools
///
/// - `web_search`: runs a query and returns titles, URLs and snippets. Offered only when a search
///   provider is configured.
/// - `fetch`: downloads a URL and returns its readable content as Markdown, paginated by
///   `start_index`. Always offered.
public final class ResearchToolKit: ToolKit, @unchecked Sendable {
    // MARK: - Properties

    public let name: String = "research"

    /// Session ledger, shared with the citation gate.
    private let registry: SourceRegistry

    /// Search backend; when `nil` no `web_search` tool is offered at all.
    private let searchProvider: (any WebSearchProvider)?

    /// Hosts fetch may contact, lowercased and matched exactly — subdomains are not implied.
    /// `nil` allows every host.
    private let allowedDomains: Set<String>?

    private let transport: any HTTPTransport

    private let timeout: TimeInterval

    /// Byte cap on a response before it is truncated, or rejected when it is binary.
    private let maxContentSize: Int

    private let extractor: any WebContentExtractor

    // MARK: - Initialization

    /// Creates a tool kit bound to one task's source ledger.
    ///
    /// - Parameters:
    ///   - registry: Ledger shared with the citation gate; the executor must hold the same instance.
    ///   - searchProvider: Search backend, or `nil` to offer `fetch` only.
    ///   - allowedDomains: Hosts fetch may contact, matched exactly; `nil` allows all of them.
    ///   - timeout: Per-request timeout in seconds (default: 30). The session's resource timeout is
    ///     twice this.
    ///   - maxContentSize: Response size cap in bytes (default: 5 MB).
    ///   - extractor: HTML-to-Markdown extractor (default: `SwiftSoupContentExtractor`).
    ///   - transport: HTTP transport, for substituting one in tests. Supplying it skips the session
    ///     configuration, but `timeout` is still applied to each request.
    public init(
        registry: SourceRegistry,
        searchProvider: (any WebSearchProvider)? = nil,
        allowedDomains: [String]? = nil,
        timeout: TimeInterval = 30,
        maxContentSize: Int = 5 * 1024 * 1024,
        extractor: (any WebContentExtractor)? = nil,
        transport: (any HTTPTransport)? = nil
    ) {
        self.registry = registry
        self.searchProvider = searchProvider
        self.allowedDomains = allowedDomains.map { Set($0.map { $0.lowercased() }) }
        self.timeout = timeout
        self.maxContentSize = maxContentSize
        self.extractor = extractor ?? SwiftSoupContentExtractor()

        if let transport {
            self.transport = transport
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout * 2
            self.transport = URLSessionTransport(session: URLSession(configuration: config), defaultTimeout: timeout)
        }
    }

    // MARK: - Factory Methods

    /// Creates a kit backed by Serper (Google SERP), resilient by default.
    ///
    /// - Parameters:
    ///   - registry: Ledger shared with the citation gate.
    ///   - apiKey: Serper API key.
    ///   - gl: Region code, for example "jp".
    ///   - hl: Language code, for example "ja".
    ///   - resilience: Cache, rate limit, circuit breaker and retry settings; `nil` calls Serper
    ///     directly, with no retry and no rate limit.
    public static func serper(
        registry: SourceRegistry,
        apiKey: String,
        gl: String? = nil,
        hl: String? = nil,
        resilience: SearchResilienceConfiguration? = .default
    ) -> ResearchToolKit {
        let base = SerperSearchProvider(apiKey: apiKey, gl: gl, hl: hl)
        let provider: any WebSearchProvider = resilience.map {
            ResilientSearchProvider(provider: base, configuration: $0)
        } ?? base
        return ResearchToolKit(registry: registry, searchProvider: provider)
    }

    // MARK: - ToolKit Protocol

    public var tools: [any Tool] {
        tools(enabled: ResearchToolID.allTools)
    }

    /// Tool IDs this instance can actually offer — the ceiling for `tools(enabled:)`.
    ///
    /// `web_search` is absent when no search provider was configured, which is how a host tells
    /// "switched off" from "cannot be switched on".
    public var availableToolIDs: Set<ResearchToolID> {
        var ids = ResearchToolID.coreTools
        if searchProvider != nil { ids.insert(.webSearch) }
        return ids
    }

    /// Returns the tools for one configuration: core tools always, the rest only if asked for.
    ///
    /// `fetch` is core and survives `enabled: []`; `web_search` is dropped whenever it is not
    /// enabled or no provider is configured. The fetch tool's description and error messages never
    /// mention search, so they read correctly with or without it.
    public func tools(enabled: Set<ResearchToolID>) -> [any Tool] {
        let effective = availableToolIDs.intersection(enabled.union(ResearchToolID.coreTools))
        var tools: [any Tool] = []
        if effective.contains(.webSearch) {
            tools.append(webSearchTool)
        }
        tools.append(fetchTool)
        return tools
    }

    // MARK: - web_search

    private var webSearchTool: BuiltInTool {
        BuiltInTool(
            name: "web_search",
            description: "Search the web. Returns titles, URLs, and snippets — snippets are leads, not facts: fetch a page before using or citing it.",
            inputSchema: .object(
                properties: [
                    "query": .string(description: "Search query"),
                    "max_results": .integer(description: "Max results (1-10, default 5)")
                ],
                required: ["query"]
            ),
            annotations: ToolAnnotations(
                title: "Web Search",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { [self] data in
            guard let provider = searchProvider else {
                throw WebSearchError.providerNotConfigured
            }
            let input = try JSONDecoder().decode(WebSearchInput.self, from: data)
            let maxResults = min(max(input.maxResults ?? 5, 1), 10)
            let results = try await provider.search(query: input.query, maxResults: maxResults)

            // Record what was observed; fetched = false, so none of it is citable yet
            for result in results {
                await registry.registerSearchResult(
                    url: result.url,
                    title: result.title,
                    snippet: result.snippet,
                    date: result.date,
                    position: result.position
                )
            }

            let output = WebSearchOutput(
                query: input.query,
                resultCount: results.count,
                results: results
            )
            let encoded = try JSONEncoder().encode(output)
            return .json(encoded)
        }
    }

    // MARK: - fetch

    private var fetchTool: BuiltInTool {
        BuiltInTool(
            name: "fetch",
            description: "Fetch a URL and return its readable content as Markdown. Only fetched pages may be cited as sources. For long pages, call again with start_index to continue reading.",
            inputSchema: .object(
                properties: [
                    "url": .string(description: "URL to fetch"),
                    "max_length": .integer(description: "Max characters to return (default 5000)"),
                    "start_index": .integer(description: "Start position for pagination (default 0)"),
                ],
                required: ["url"]
            ),
            annotations: ToolAnnotations(
                title: "Fetch",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(FetchInput.self, from: data)
            let url = try validateURL(input.url)
            let maxLength = input.maxLength ?? 5000
            let startIndex = input.startIndex ?? 0

            let request = HTTPRequest(
                method: "GET",
                url: url,
                headers: [
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                    "Accept-Language": "ja,en;q=0.9",
                ],
                timeout: timeout
            )

            let response = try await transport.send(request)
            let responseData = response.body

            guard (200...299).contains(response.status) else {
                throw ResearchToolError.httpError(statusCode: response.status)
            }

            let contentType = response.headers["Content-Type"]

            // Binary payloads (PDF, images, ...) cannot become text, so they are an error rather
            // than a truncation. Only oversized bodies are inspected here; a small binary one falls
            // through to the text path below.
            if responseData.count > maxContentSize {
                let ct = contentType?.lowercased() ?? ""
                if ct.contains("application/pdf") || ct.contains("application/octet-stream")
                    || ct.contains("image/") || ct.contains("audio/") || ct.contains("video/") {
                    throw ResearchToolError.contentTooLarge(size: responseData.count, maxSize: maxContentSize)
                }
            }

            // Text and HTML are truncated and processing continues
            let processData: Data
            let wasTruncated: Bool
            if responseData.count > maxContentSize {
                processData = Data(responseData.prefix(maxContentSize))
                wasTruncated = true
            } else {
                processData = responseData
                wasTruncated = false
            }

            guard let content = TextEncodingSupport.decode(processData, contentType: contentType) else {
                throw ResearchToolError.encodingError
            }

            // Detect HTML, then extract Markdown
            let title: String?
            let fullText: String

            if Self.isHTMLContent(contentType: contentType, content: content) {
                let extracted = try extractor.extract(html: content, url: url)
                title = extracted.title
                fullText = extracted.content
            } else {
                title = nil
                fullText = content
            }

            // Record the successful fetch. The whole extracted text is stored, not just the page
            // slice returned below, and the URL becomes citable.
            await registry.registerFetch(url: url.absoluteString, title: title, content: fullText)

            // Pagination
            let totalLength = fullText.count
            let safeStartIndex = min(startIndex, max(0, totalLength - 1))
            let endIndex = min(safeStartIndex + maxLength, totalLength)
            let hasMore = endIndex < totalLength

            let paginatedContent: String
            if safeStartIndex < totalLength {
                let start = fullText.index(fullText.startIndex, offsetBy: safeStartIndex)
                let end = fullText.index(fullText.startIndex, offsetBy: endIndex)
                paginatedContent = String(fullText[start..<end])
            } else {
                paginatedContent = ""
            }

            var result = FetchResult(
                url: url.absoluteString,
                title: title,
                content: paginatedContent,
                contentLength: totalLength,
                startIndex: safeStartIndex,
                hasMore: hasMore,
                nextHint: nil,
                wasTruncated: wasTruncated
            )

            if hasMore {
                result.nextHint = "Call fetch with start_index=\(endIndex) to continue reading."
            }

            let output = try JSONEncoder().encode(result)
            return .json(output)
        }
    }

    // MARK: - Domain Validation

    /// Rejects anything that is not an http(s) URL on an allowed host.
    private func validateURL(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString) else {
            throw ResearchToolError.invalidURL(urlString)
        }

        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ResearchToolError.unsupportedScheme(url.scheme ?? "unknown")
        }

        if let allowedDomains = allowedDomains,
           let host = url.host?.lowercased(),
           !allowedDomains.contains(host) {
            throw ResearchToolError.domainNotAllowed(host, allowed: Array(allowedDomains))
        }

        return url
    }

    // MARK: - HTML Detection

    /// Reports whether the body should go through HTML extraction.
    ///
    /// Either an HTML content type or a body starting with a doctype or `<html>` counts, so a page
    /// served as `text/plain` is still extracted.
    private static func isHTMLContent(contentType: String?, content: String) -> Bool {
        // By content type
        if let ct = contentType?.lowercased() {
            if ct.contains("text/html") || ct.contains("application/xhtml+xml") {
                return true
            }
        }

        // By leading tag
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") {
            return true
        }

        return false
    }
}

// MARK: - Input / Output Types

private struct WebSearchInput: Codable {
    var query: String
    var maxResults: Int?

    enum CodingKeys: String, CodingKey {
        case query
        case maxResults = "max_results"
    }
}

private struct WebSearchOutput: Codable {
    var query: String
    var resultCount: Int
    var results: [WebSearchResult]

    enum CodingKeys: String, CodingKey {
        case query
        case resultCount = "result_count"
        case results
    }
}

private struct FetchInput: Codable {
    var url: String
    var maxLength: Int?
    var startIndex: Int?

    enum CodingKeys: String, CodingKey {
        case url
        case maxLength = "max_length"
        case startIndex = "start_index"
    }
}

private struct FetchResult: Codable {
    var url: String
    var title: String?
    var content: String
    var contentLength: Int
    var startIndex: Int
    var hasMore: Bool
    var nextHint: String?
    var wasTruncated: Bool

    enum CodingKeys: String, CodingKey {
        case url, title, content
        case contentLength = "content_length"
        case startIndex = "start_index"
        case hasMore = "has_more"
        case nextHint = "next_hint"
        case wasTruncated = "was_truncated"
    }
}

// MARK: - Errors

/// Failures from the `fetch` tool and its URL validation.
///
/// Every message is written for the model that will read it: what went wrong, and what to try
/// instead, so a dead URL turns into a different tool call rather than a dead end.
public enum ResearchToolError: Error, LocalizedError {
    case invalidURL(String)
    case unsupportedScheme(String)
    case domainNotAllowed(String, allowed: [String])
    case invalidResponse
    case httpError(statusCode: Int)
    case contentTooLarge(size: Int, maxSize: Int)
    case encodingError

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url). Use URLs observed this session (search results or links in fetched pages) instead of guessing."
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme: \(scheme). Only http and https are supported."
        case .domainNotAllowed(let domain, let allowed):
            return "Domain '\(domain)' is not allowed. Allowed domains: \(allowed.joined(separator: ", ")). Try a different source."
        case .invalidResponse:
            return "Invalid server response. Try a different URL observed this session."
        case .httpError(let statusCode):
            switch statusCode {
            case 401, 403:
                return "Access blocked (HTTP \(statusCode)). Try a different source."
            case 404:
                return "Page not found (HTTP 404). Use URLs observed this session instead of guessing."
            case 429:
                return "Rate limited (HTTP 429). Wait before retrying, or try a different source."
            case 500...599:
                return "Server error (HTTP \(statusCode)). The server may be temporarily unavailable. Try again later or use a different source."
            default:
                return "HTTP error \(statusCode). Try a different URL observed this session."
            }
        case .contentTooLarge(let size, let maxSize):
            return "Content too large: \(size) bytes (max: \(maxSize) bytes). This is a binary file (PDF, image, etc.) that cannot be processed as text. Look for an HTML version instead."
        case .encodingError:
            return "Cannot decode the response encoding. Try a different source."
        }
    }
}
