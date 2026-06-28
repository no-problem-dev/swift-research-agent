import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient
import LLMTool
import ResearchStore

// MARK: - ResearchToolKit

/// Web 調査ツール（web_search / fetch）を提供する ToolKit。
///
/// LLMMCP の WebToolKit / WebSearchToolKit からの移植（移植元は保守凍結）。
/// 最大の違いは `SourceRegistry` への記帳: 観測した URL と fetch 成功・本文を
/// 台帳に記録し、出典検証ゲートの照合材料にする（MediaToolKit が
/// MediaSessionStore へ成果物を書き込むのと同型）。
///
/// 責務は素材の提供と記帳まで — 引用の検証はゲート側（ResearchAgent）が行う。
///
/// ## 使用例
///
/// ```swift
/// let registry = SourceRegistry()
/// let toolKit = ResearchToolKit(
///     registry: registry,
///     searchProvider: SerperSearchProvider(apiKey: key, gl: "jp", hl: "ja")
/// )
/// ```
///
/// ## 提供されるツール
///
/// - `web_search`: クエリでWeb検索を実行し、結果一覧を返す（プロバイダー設定時のみ）
/// - `fetch`: URLからコンテンツを取得（HTML自動Markdown変換、ページネーション対応）
public final class ResearchToolKit: ToolKit, @unchecked Sendable {
    // MARK: - Properties

    public let name: String = "research"

    /// 観測ソースの台帳（セッションスコープ、ゲートと共有）
    private let registry: SourceRegistry

    /// 検索プロバイダー（nil の場合 web_search ツールを提供しない）
    private let searchProvider: (any WebSearchProvider)?

    /// 許可されたドメイン（nilの場合は全て許可）
    private let allowedDomains: Set<String>?

    /// HTTP トランスポート
    private let transport: any HTTPTransport

    /// タイムアウト秒数
    private let timeout: TimeInterval

    /// 最大コンテンツサイズ（バイト）
    private let maxContentSize: Int

    /// コンテンツ抽出器
    private let extractor: any WebContentExtractor

    // MARK: - Initialization

    /// ResearchToolKitを作成
    ///
    /// - Parameters:
    ///   - registry: 観測ソースの台帳（ゲートと共有するセッションスコープの actor）
    ///   - searchProvider: 検索プロバイダー（nil で web_search を提供しない）
    ///   - allowedDomains: 許可するドメインの配列（nilの場合は全て許可）
    ///   - timeout: リクエストのタイムアウト秒数（デフォルト: 30）
    ///   - maxContentSize: 最大取得サイズ（デフォルト: 5MB）
    ///   - extractor: コンテンツ抽出器（デフォルト: SwiftSoupContentExtractor）
    ///   - transport: HTTP トランスポート（テスト時に差し替え可能）
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

    /// Serper（Google SERP）検索付きの ResearchToolKit を作成
    ///
    /// - Parameters:
    ///   - registry: 観測ソースの台帳
    ///   - apiKey: Serper APIキー
    ///   - gl: 地域コード（例: "jp"）
    ///   - hl: 言語コード（例: "ja"）
    ///   - resilience: レジリエンス設定（nil でレジリエンスなし）
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

    /// 構成済みプロバイダから提供可能なツール ID（`tools(enabled:)` の上限）。
    /// ホスト UI はこれで「キー未設定で使えないツール」を判別できる。
    public var availableToolIDs: Set<ResearchToolID> {
        var ids = ResearchToolID.coreTools
        if searchProvider != nil { ids.insert(.webSearch) }
        return ids
    }

    /// enabled で選別したツール一式。コアツール（fetch）は常に含まれ、
    /// プロバイダ未構成のツールは enabled に含めても落ちる。
    /// fetch の説明・エラー文はツール構成に依存しない表現で書かれている
    /// （web_search の有無どちらでも正しい誘導になる）。
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

            // 観測した URL を台帳へ記帳（fetched=false: 引用にはまだ使えない）
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

            // バイナリコンテンツ（PDF・画像等）はテキスト変換不可のためエラー
            if responseData.count > maxContentSize {
                let ct = contentType?.lowercased() ?? ""
                if ct.contains("application/pdf") || ct.contains("application/octet-stream")
                    || ct.contains("image/") || ct.contains("audio/") || ct.contains("video/") {
                    throw ResearchToolError.contentTooLarge(size: responseData.count, maxSize: maxContentSize)
                }
            }

            // テキスト/HTMLコンテンツは切り詰めて処理続行
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

            // HTML判定 + Markdown抽出
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

            // fetch 成功を台帳へ記帳（全文を照合材料として保持。引用可になる）
            await registry.registerFetch(url: url.absoluteString, title: title, content: fullText)

            // ページネーション処理
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

    /// ドメインが許可されているかチェック
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

    /// コンテンツがHTMLかどうかを判定
    ///
    /// Content-Typeヘッダーと先頭のHTMLタグの両方で判定します。
    private static func isHTMLContent(contentType: String?, content: String) -> Bool {
        // Content-Typeベースの判定
        if let ct = contentType?.lowercased() {
            if ct.contains("text/html") || ct.contains("application/xhtml+xml") {
                return true
            }
        }

        // 先頭タグベースの判定
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

/// ResearchToolKitのエラー
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
