import Foundation
import ResearchStore

/// researcher の回答を決定論的に検証するゲート。
///
/// SourceRegistry（このタスクでツールが記帳した観測ソースの台帳）と照合する:
/// 1. 出典必須: 回答は出典 URL を引用していること（ツールを使わない回答は URL を
///    出典にできないため、間接的に web_search / fetch を強制する）
/// 2. 実在: 引用 URL が台帳に存在すること（記憶・捏造 URL の排除）
/// 3. 取得済み: 引用 URL が fetch 成功済みであること
///    （fetch 成功 = 実在 + 到達可能 + 内容確認済み。検索スニペットだけを根拠にした
///    引用を排除し、回答後の生存確認 GET を不要にする）
///
/// URL は正規化（トラッキングパラメータ・フラグメント・www 等の畳み込み）してから
/// 照合するため、表記ゆれによる偽陰性が起きない。ネットワークも LLM も使わない。
public enum ResearchCitationGate {
    /// 回答テキストを台帳と照合し、違反リストを返す（空 = 合格）。
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

    /// 違反リストから是正メッセージを組み立てる。
    public static func corrective(issues: [String]) -> String {
        """
        Your previous answer failed source validation:
        \(issues.map { "- \($0)" }.joined(separator: "\n"))
        Fix the answer: cite only URLs whose pages you fetched in this task. \
        Use web_search to find sources and fetch to verify their content, \
        and remove any claim or source you cannot verify.
        """
    }

    /// テキストから URL を抽出する（末尾の約物・閉じ括弧は除去、重複排除）。
    public static func urls(in text: String) -> [String] {
        let pattern = #"https?://[^\s<>"'`\)\]）」]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            var url = String(text[matchRange])
            // URL は ASCII のみ: 句点など CJK 文字が直結したケース（…/a。詳細は）を切り落とす
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
