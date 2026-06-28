import Foundation

// MARK: - WebSearchProvider Protocol

/// 検索エンジンバックエンドを差し替え可能にする抽象プロトコル。
///
/// ## 使用例
///
/// ```swift
/// let provider = SerperSearchProvider(apiKey: "YOUR_API_KEY", gl: "jp", hl: "ja")
/// let results = try await provider.search(query: "Swift concurrency", maxResults: 5)
/// ```
public protocol WebSearchProvider: Sendable {
    /// 検索を実行する。
    ///
    /// - Parameters:
    ///   - query: 検索クエリ
    ///   - maxResults: 最大結果数
    /// - Returns: 検索結果の配列
    func search(query: String, maxResults: Int) async throws -> [WebSearchResult]
}

// MARK: - WebSearchResult

/// Web検索の結果
///
/// プロバイダーが返すメタデータ（日付・順位）は落とさず保持する。
/// 出典の鮮度・信頼度判断の素材になる。
public struct WebSearchResult: Codable, Sendable {
    /// ページタイトル
    public let title: String

    /// ページURL
    public let url: String

    /// 検索結果のスニペット
    public let snippet: String

    /// プロバイダーが返した日付文字列（公開日など）
    public let date: String?

    /// 検索結果での順位（1 始まり）
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

/// APIキー未設定時のフォールバックプロバイダー。
///
/// 検索実行時に設定方法を案内するエラーを返す。
/// ビルドは通るが、実行時にユーザーに設定を促す。
public struct UnconfiguredSearchProvider: WebSearchProvider {
    public init() {}

    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        throw WebSearchError.providerNotConfigured
    }
}

// MARK: - Errors

/// Web検索のエラー
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
