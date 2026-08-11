import Foundation

// MARK: - WebContentExtractor Protocol

/// Turns a fetched HTML page into the text the model reads and the ledger stores.
///
/// Implement it to replace the default extraction strategy; `SwiftSoupContentExtractor` ships as
/// the default.
///
/// ## Example
///
/// ```swift
/// let extractor = SwiftSoupContentExtractor()
/// let content = try extractor.extract(html: htmlString, url: pageURL)
/// print(content.content) // Markdown text
/// ```
public protocol WebContentExtractor: Sendable {
    /// Extracts the readable part of an HTML document.
    ///
    /// - Parameters:
    ///   - html: Raw HTML.
    ///   - url: Page URL, used to absolutize relative links.
    /// - Returns: Title, Markdown body and page metadata.
    func extract(html: String, url: URL) throws -> ExtractedContent
}

// MARK: - ExtractedContent

/// What extraction produced: the text returned to the model and stored as the source body.
public struct ExtractedContent: Sendable {
    /// Page title; `nil` when the page offers neither an `og:title` nor a `<title>`.
    public let title: String?

    /// The readable body, converted to Markdown.
    public let content: String

    /// Page metadata that survived extraction: description, `og:*`, canonical.
    public let metadata: [String: String]

    public init(title: String?, content: String, metadata: [String: String] = [:]) {
        self.title = title
        self.content = content
        self.metadata = metadata
    }
}
