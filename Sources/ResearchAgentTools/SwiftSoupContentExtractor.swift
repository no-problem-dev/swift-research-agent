import Foundation
import SwiftSoup

// MARK: - SwiftSoupContentExtractor

/// Default extraction: strip the page chrome, score the DOM for the body, convert it to Markdown.
///
/// The scoring pass takes `<article>` or `<main>` when either exists, otherwise the highest
/// scoring block, and falls back to the whole `<body>` when nothing scores well — so a page it
/// cannot read yields chrome-free noise rather than nothing at all.
///
/// ## Example
///
/// ```swift
/// let extractor = SwiftSoupContentExtractor()
/// let result = try extractor.extract(html: htmlString, url: URL(string: "https://example.com")!)
/// print(result.content) // Markdown
/// ```
public struct SwiftSoupContentExtractor: WebContentExtractor, Sendable {

    public init() {}

    // MARK: - WebContentExtractor

    /// Extracts a page's title, main content as Markdown, and metadata.
    ///
    /// Title and metadata are read before cleaning, so removing `<header>` and friends cannot lose
    /// them. Links are absolutized against `url`; `data:`, `javascript:` and in-page anchors are
    /// dropped instead.
    ///
    /// - Parameters:
    ///   - html: Raw HTML.
    ///   - url: Page URL, used to absolutize relative links.
    /// - Returns: Title, Markdown body and page metadata.
    /// - Throws: Errors from the HTML parser. The document-without-a-body case is effectively
    ///   unreachable, since the parser synthesizes one.
    public func extract(html: String, url: URL) throws -> ExtractedContent {
        let doc = try SwiftSoup.parse(html, url.absoluteString)

        // Metadata first: cleaning removes the elements it lives in
        let metadata = Self.extractMetadata(from: doc)
        let title = Self.extractTitle(from: doc, metadata: metadata)

        // Clean the DOM
        Self.cleanDOM(doc)

        // Score the remaining blocks to find the body
        let contentElement = try Self.findMainContent(in: doc)

        // Convert to Markdown
        let markdown = Self.convertToMarkdown(element: contentElement, baseURL: url)

        // Tidy up
        let cleaned = Self.postProcess(markdown)

        return ExtractedContent(title: title, content: cleaned, metadata: metadata)
    }

    // MARK: - (A) DOM Cleaning

    /// Removes what is never body text: scripts, styles, chrome, forms, controls, comments.
    private static func cleanDOM(_ doc: Document) {
        let selectorsToRemove = [
            "script", "style", "nav", "footer", "aside", "header",
            "svg", "noscript", "form", "iframe", "button",
            "[role=navigation]", "[role=banner]", "[role=complementary]", "[role=contentinfo]",
        ]
        let selector = selectorsToRemove.joined(separator: ", ")
        if let elements = try? doc.select(selector) {
            _ = try? elements.remove()
        }
        // Comment nodes too
        if let body = doc.body() {
            removeComments(from: body)
        }
    }

    /// Removes comment nodes throughout a subtree.
    private static func removeComments(from node: Node) {
        var i = 0
        while i < node.childNodeSize() {
            let child = node.childNode(i)
            if child is Comment {
                try? child.remove()
            } else {
                removeComments(from: child)
                i += 1
            }
        }
    }

    // MARK: - (B) Readability Scoring

    /// Picks the element holding the body text.
    ///
    /// Prefers `<article>`, then `<main>`, then the highest scoring block, and settles for the
    /// whole `<body>` when nothing scores above the threshold.
    private static func findMainContent(in doc: Document) throws -> Element {
        // 1. Take <article> or <main> as-is when either has text
        if let article = try? doc.select("article").first(), let text = try? article.text(), !text.isEmpty {
            return article
        }
        if let main = try? doc.select("main").first(), let text = try? main.text(), !text.isEmpty {
            return main
        }

        // 2. Score every div, section, td and pre
        guard let body = doc.body() else {
            throw SwiftSoupExtractorError.noBody
        }

        let candidates = try body.select("div, section, td, pre")
        var bestScore = 0
        var bestElement: Element?

        for candidate in candidates.array() {
            let score = scoreElement(candidate)
            if score > bestScore {
                bestScore = score
                bestElement = candidate
            }
        }

        // 3. Accept the best block only if it clears the threshold, else fall back to body
        if bestScore > 20, let best = bestElement {
            return best
        }

        return body
    }

    /// Scores how much a block looks like body text.
    ///
    /// Class and id wording, own-text length, direct paragraph children and comma count add; link
    /// density above half and chrome-sounding names subtract.
    private static func scoreElement(_ element: Element) -> Int {
        var score = 0

        // What the class and id call this block
        let classId = ((try? element.className()) ?? "") + " " + (element.id())
        let classIdLower = classId.lowercased()

        let positivePatterns = [
            "article", "body", "content", "entry", "main", "page",
            "post", "text", "blog", "story", "prose",
        ]
        let negativePatterns = [
            "combx", "comment", "contact", "foot", "footer",
            "masthead", "media", "meta", "nav", "outbrain",
            "promo", "related", "scroll", "shoutbox", "sidebar",
            "sponsor", "shopping", "tags", "tool", "widget", "banner",
        ]

        for pattern in positivePatterns {
            if classIdLower.contains(pattern) {
                score += 25
                break
            }
        }
        for pattern in negativePatterns {
            if classIdLower.contains(pattern) {
                score -= 25
                break
            }
        }

        // Longer own text scores higher
        let textLength = element.ownText().count
        if textLength > 500 {
            score += 30
        } else if textLength > 100 {
            score += 20
        }

        // Direct <p> children
        let directParagraphs = element.children().array().filter { $0.tagName() == "p" }
        score += directParagraphs.count * 10

        // Mostly-links blocks are navigation
        let fullText = (try? element.text()) ?? ""
        let linkText = (try? element.select("a").text()) ?? ""
        if !fullText.isEmpty {
            let linkDensity = Double(linkText.count) / Double(fullText.count)
            if linkDensity > 0.5 {
                score -= 50
            }
        }

        // Commas, Western and CJK, as a proxy for prose
        let commaCount = fullText.filter { $0 == "," || $0 == "\u{3001}" }.count
        score += commaCount * 3

        return score
    }

    // MARK: - (C) Markdown Conversion

    /// Converts an element tree into Markdown lines.
    private static func convertToMarkdown(element: Element, baseURL: URL) -> String {
        var lines: [String] = []
        walkNode(element, baseURL: baseURL, lines: &lines, listDepth: 0, listIndex: nil)
        return lines.joined(separator: "\n")
    }

    /// Walks a node, appending its Markdown lines.
    private static func walkNode(
        _ node: Node,
        baseURL: URL,
        lines: inout [String],
        listDepth: Int,
        listIndex: Int?
    ) {
        if let textNode = node as? TextNode {
            let text = textNode.getWholeText()
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(text)
            }
            return
        }

        guard let element = node as? Element else {
            // Any other node type: walk the children
            for child in node.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            }
            return
        }

        let tag = element.tagName().lowercased()

        switch tag {
        // Headings
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.last!))!
            let prefix = String(repeating: "#", count: level)
            let text = (try? element.text()) ?? ""
            if !text.isEmpty {
                lines.append("")
                lines.append("\(prefix) \(text)")
                lines.append("")
            }

        // Links
        case "a":
            let text = (try? element.text()) ?? ""
            let href = resolveURL(try? element.attr("href"), base: baseURL)
            if !text.isEmpty, let href = href {
                lines.append("[\(text)](\(href))")
            } else if !text.isEmpty {
                lines.append(text)
            }

        // Images
        case "img":
            let alt = (try? element.attr("alt")) ?? ""
            let src = resolveURL(try? element.attr("src"), base: baseURL)
            if let src = src {
                lines.append("![\(alt)](\(src))")
            }

        // Emphasis
        case "strong", "b":
            let text = (try? element.text()) ?? ""
            if !text.isEmpty {
                lines.append("**\(text)**")
            }

        case "em", "i":
            let text = (try? element.text()) ?? ""
            if !text.isEmpty {
                lines.append("*\(text)*")
            }

        // Code
        case "code":
            // Inside <pre> this is a fenced block; the pre case delegates here to build it
            if element.parent()?.tagName().lowercased() == "pre" {
                let text = (try? element.text()) ?? ""
                let lang = (try? element.className()) ?? ""
                let langHint = lang.replacingOccurrences(of: "language-", with: "")
                    .components(separatedBy: " ").first ?? ""
                lines.append("")
                lines.append("```\(langHint)")
                lines.append(text)
                lines.append("```")
                lines.append("")
            } else {
                let text = (try? element.text()) ?? ""
                if !text.isEmpty {
                    lines.append("`\(text)`")
                }
            }

        // Preformatted blocks
        case "pre":
            // Detect the <pre><code>...</code></pre> pattern
            if let codeChild = element.children().array().first(where: { $0.tagName() == "code" }) {
                walkNode(codeChild, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            } else {
                let text = (try? element.text()) ?? ""
                lines.append("")
                lines.append("```")
                lines.append(text)
                lines.append("```")
                lines.append("")
            }

        // Unordered lists
        case "ul":
            lines.append("")
            for child in element.children().array() where child.tagName() == "li" {
                let indent = String(repeating: "  ", count: listDepth)
                var itemLines: [String] = []
                walkNode(child, baseURL: baseURL, lines: &itemLines, listDepth: listDepth + 1, listIndex: nil)
                let itemText = itemLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !itemText.isEmpty {
                    lines.append("\(indent)- \(itemText)")
                }
            }
            lines.append("")

        // Ordered lists
        case "ol":
            lines.append("")
            for (idx, child) in element.children().array().filter({ $0.tagName() == "li" }).enumerated() {
                let indent = String(repeating: "  ", count: listDepth)
                var itemLines: [String] = []
                walkNode(child, baseURL: baseURL, lines: &itemLines, listDepth: listDepth + 1, listIndex: idx + 1)
                let itemText = itemLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !itemText.isEmpty {
                    lines.append("\(indent)\(idx + 1). \(itemText)")
                }
            }
            lines.append("")

        // List items reached directly: just expand the children
        case "li":
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            }

        // Block quotes
        case "blockquote":
            var quotedLines: [String] = []
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &quotedLines, listDepth: listDepth, listIndex: listIndex)
            }
            let quoted = quotedLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !quoted.isEmpty {
                lines.append("")
                for line in quoted.components(separatedBy: "\n") {
                    lines.append("> \(line)")
                }
                lines.append("")
            }

        // Tables
        case "table":
            let tableMarkdown = convertTable(element, baseURL: baseURL)
            if !tableMarkdown.isEmpty {
                lines.append("")
                lines.append(tableMarkdown)
                lines.append("")
            }

        // Paragraphs
        case "p":
            var pLines: [String] = []
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &pLines, listDepth: listDepth, listIndex: listIndex)
            }
            let text = pLines.joined(separator: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append("")
                lines.append(text)
                lines.append("")
            }

        // Line breaks
        case "br":
            lines.append("")

        // Horizontal rules
        case "hr":
            lines.append("")
            lines.append("---")
            lines.append("")

        // Containers with no Markdown of their own
        case "div", "section", "article", "main", "span", "figure", "figcaption", "details", "summary":
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            }

        // Table internals are already handled by the table case
        case "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "colgroup", "col":
            break

        default:
            // Unknown elements: expand the children
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            }
        }
    }

    /// Converts a table to a GitHub-flavoured Markdown table.
    ///
    /// Takes the header from `<thead>` or from leading `<th>` cells, and promotes the first body
    /// row when there is neither. Short rows are padded so every row has the same column count.
    private static func convertTable(_ table: Element, baseURL: URL) -> String {
        var headerCells: [String] = []
        var rows: [[String]] = []

        // Header row
        if let thead = try? table.select("thead").first() {
            if let tr = try? thead.select("tr").first() {
                headerCells = (try? tr.select("th, td").array().map { (try? $0.text()) ?? "" }) ?? []
            }
        }

        // No thead: try the first row's <th> cells
        if headerCells.isEmpty {
            if let firstRow = try? table.select("tr").first() {
                let ths = (try? firstRow.select("th").array()) ?? []
                if !ths.isEmpty {
                    headerCells = ths.map { (try? $0.text()) ?? "" }
                }
            }
        }

        // Body rows
        let allRows = (try? table.select("tr").array()) ?? []
        let startIndex = headerCells.isEmpty ? 0 : 1
        for i in startIndex..<allRows.count {
            let cells = (try? allRows[i].select("td, th").array().map { (try? $0.text()) ?? "" }) ?? []
            if !cells.isEmpty {
                rows.append(cells)
            }
        }

        // Still no header: promote the first body row
        if headerCells.isEmpty, !rows.isEmpty {
            headerCells = rows.removeFirst()
        }

        guard !headerCells.isEmpty else { return "" }

        // Pad every row to the widest one
        let colCount = max(headerCells.count, rows.map { $0.count }.max() ?? 0)
        let normalizedHeader = headerCells + Array(repeating: "", count: max(0, colCount - headerCells.count))

        var result = "| " + normalizedHeader.joined(separator: " | ") + " |"
        result += "\n| " + normalizedHeader.map { _ in "---" }.joined(separator: " | ") + " |"

        for row in rows {
            let normalizedRow = row + Array(repeating: "", count: max(0, colCount - row.count))
            result += "\n| " + normalizedRow.joined(separator: " | ") + " |"
        }

        return result
    }

    // MARK: - Metadata Extraction

    /// Reads description, `og:*` and canonical from the document, skipping empty values.
    private static func extractMetadata(from doc: Document) -> [String: String] {
        var metadata: [String: String] = [:]

        // og:title
        if let ogTitle = try? doc.select("meta[property=og:title]").first()?.attr("content"),
           !ogTitle.isEmpty {
            metadata["og:title"] = ogTitle
        }

        // description
        if let desc = try? doc.select("meta[name=description]").first()?.attr("content"),
           !desc.isEmpty {
            metadata["description"] = desc
        }

        // og:description
        if let ogDesc = try? doc.select("meta[property=og:description]").first()?.attr("content"),
           !ogDesc.isEmpty {
            metadata["og:description"] = ogDesc
        }

        // og:image
        if let ogImage = try? doc.select("meta[property=og:image]").first()?.attr("content"),
           !ogImage.isEmpty {
            metadata["og:image"] = ogImage
        }

        // canonical
        if let canonical = try? doc.select("link[rel=canonical]").first()?.attr("href"),
           !canonical.isEmpty {
            metadata["canonical"] = canonical
        }

        return metadata
    }

    /// Returns the page title, preferring `og:title` over `<title>`.
    private static func extractTitle(from doc: Document, metadata: [String: String]) -> String? {
        if let ogTitle = metadata["og:title"] {
            return ogTitle
        }
        if let title = try? doc.title(), !title.isEmpty {
            return title
        }
        return nil
    }

    // MARK: - Helpers

    /// Absolutizes a link against the page URL.
    ///
    /// - Returns: `nil` for empty links, `data:`, `javascript:` and in-page anchors, so none of
    ///   them reach the Markdown.
    private static func resolveURL(_ href: String?, base: URL) -> String? {
        guard let href = href, !href.isEmpty else { return nil }
        // Skip data: URLs, javascript: and in-page anchors
        if href.hasPrefix("data:") || href.hasPrefix("javascript:") || href.hasPrefix("#") {
            return nil
        }
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            return href
        }
        return URL(string: href, relativeTo: base)?.absoluteString
    }

    /// Collapses runs of blank lines, strips trailing whitespace, and trims the ends.
    private static func postProcess(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }

        // At most one blank line in a row
        var result: [String] = []
        var previousWasEmpty = false

        for line in lines {
            if line.isEmpty {
                if !previousWasEmpty {
                    result.append("")
                }
                previousWasEmpty = true
            } else {
                result.append(line)
                previousWasEmpty = false
            }
        }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

private enum SwiftSoupExtractorError: Error, LocalizedError {
    case noBody

    var errorDescription: String? {
        switch self {
        case .noBody:
            return "HTML document has no <body> element."
        }
    }
}
