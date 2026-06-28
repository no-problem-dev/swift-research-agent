import Foundation

// MARK: - WebContentExtractor Protocol

/// HTML コンテンツ抽出の抽象プロトコル。
///
/// 異なる抽出戦略を差し替え可能にする。`WebSearchProvider` パターンに倣い、
/// デフォルト実装として `SwiftSoupContentExtractor` を提供する。
///
/// ## 使用例
///
/// ```swift
/// let extractor = SwiftSoupContentExtractor()
/// let content = try extractor.extract(html: htmlString, url: pageURL)
/// print(content.content) // Markdown形式のテキスト
/// ```
public protocol WebContentExtractor: Sendable {
    /// HTML からコンテンツを抽出する。
    ///
    /// - Parameters:
    ///   - html: 生の HTML 文字列
    ///   - url: ページの URL（相対リンクの絶対化に使う）
    /// - Returns: 抽出されたコンテンツ
    func extract(html: String, url: URL) throws -> ExtractedContent
}

// MARK: - ExtractedContent

/// 抽出されたWebコンテンツ
public struct ExtractedContent: Sendable {
    /// ページタイトル
    public let title: String?

    /// 抽出されたコンテンツ（Markdown形式）
    public let content: String

    /// メタデータ（description, og:image, canonical等）
    public let metadata: [String: String]

    public init(title: String?, content: String, metadata: [String: String] = [:]) {
        self.title = title
        self.content = content
        self.metadata = metadata
    }
}
