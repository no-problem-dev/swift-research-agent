import Foundation
import ResearchStore

/// Checks an answer's citations against the ledger of what this task actually fetched.
///
/// Every http(s) URL in the answer must resolve, after normalization, to a record whose `fetched`
/// is `true`. Three things are reported as violations:
///
/// 1. The answer cites no URL at all. Reported as a single violation, and nothing else is
///    checked — since only tool results can supply a URL, this indirectly forces tool use.
/// 2. A cited URL has no record: it was never returned by `web_search` or `fetch` in this task.
/// 3. A cited URL has a record but was only ever a search hit; the snippet is not evidence.
///
/// Matching is exact on the normalized key, so `www.`, tracking parameters, a fragment or a
/// trailing slash make no difference, while a different path or query is a different page and
/// counts as uncited. No network and no LLM are involved, so the same text always scores the same.
///
/// What it cannot see: whether a fetched page supports the sentence it is attached to. Once a page
/// is fetched it can be cited for anything, including a claim it contradicts, and the stored page
/// text is never compared against the answer. This constrains where citations come from, not
/// whether they are apt.
public enum ResearchCitationGate {
    /// Lists every citation violation in an answer; an empty list means it passed.
    ///
    /// Never throws and never edits the answer — acting on the violations is the caller's job.
    /// The messages are written for the model to read and say what to do instead.
    public static func validate(text: String, registry: SourceRegistry) async -> [String] {
        var issues: [String] = []
        let cited = urls(in: text)

        if cited.isEmpty {
            issues.append(
                "No source URLs are cited. Research answers must cite the source URLs you actually used (from web_search / fetch results)."
            )
            return issues
        }

        for url in cited {
            guard let record = await registry.record(citing: url) else {
                issues.append(
                    "Cited URL \(url) does not appear in any tool result of this task — cite only sources you actually found or fetched."
                )
                continue
            }
            if !record.fetched {
                issues.append(
                    "Cited URL \(url) appeared only in search results and was never fetched — fetch it to verify the content before citing, or cite a page you did fetch."
                )
            }
        }
        return issues
    }

    /// Builds the follow-up turn that tells the model how to repair a rejected answer.
    ///
    /// Lists every violation and restates the rule: cite only pages fetched in this task, and drop
    /// what cannot be verified. Append it as a user message before running the loop again.
    public static func corrective(issues: [String]) -> String {
        """
        Your previous answer failed source validation:
        \(issues.map { "- \($0)" }.joined(separator: "\n"))
        Fix the answer: cite only URLs whose pages you fetched in this task. \
        Use web_search to find sources and fetch to verify their content, \
        and remove any claim or source you cannot verify.
        """
    }

    /// Extracts the http(s) URLs from prose, in order of first appearance and without duplicates.
    ///
    /// Tuned for text a model writes: whitespace, angle brackets, quotes and closing brackets end
    /// a URL, it is cut at the first non-ASCII character, and trailing punctuation (including CJK
    /// punctuation) is removed. A match no longer than `https://` itself is discarded.
    public static func urls(in text: String) -> [String] {
        let pattern = #"https?://[^\s<>"'`\)\]）」]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            var url = String(text[matchRange])
            // URLs are ASCII: cut at the first non-ASCII character, which is where CJK punctuation
            // and following prose run straight into the URL with no separator
            if let nonASCII = url.firstIndex(where: { !$0.isASCII }) {
                url = String(url[..<nonASCII])
            }
            while let last = url.last, ".,。、;:!?".contains(last) { url.removeLast() }
            guard url.count > "https://".count else { continue }
            if seen.insert(url).inserted { result.append(url) }
        }
        return result
    }
}
