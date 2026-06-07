import Foundation

/// 引用照合のための URL 正規化。
///
/// 同一ページを指す表記ゆれ（トラッキングパラメータ・フラグメント・www・末尾スラッシュ等）を
/// 畳み込んで台帳キーの一意性を保証する。node-DeepResearch の `normalizeUrl` を参考に、
/// 変換は決定的・保守的（意味を変えうる書き換えはしない）に留める。
public enum URLNormalization {
    /// 除去するトラッキング系クエリパラメータ。
    private static let trackingParameters: Set<String> = [
        "gclid", "fbclid", "yclid", "msclkid", "dclid", "igshid", "twclid",
        "mc_cid", "mc_eid", "_ga", "_gl", "ref_src", "ref_url", "cmpid",
        "spm", "share_id", "xtor",
    ]

    /// URL 文字列を正規化する。http(s) 以外・パース不能は nil。
    public static func normalize(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(),
              !host.isEmpty
        else { return nil }

        components.scheme = scheme

        // www. と既定ポートの除去
        if host.hasPrefix("www."), host.count > 4 {
            host = String(host.dropFirst(4))
        }
        components.host = host
        if let port = components.port,
           (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            components.port = nil
        }

        // フラグメントはページ内位置なので引用同一性に含めない
        components.fragment = nil

        // トラッキングパラメータ除去 + 残りをソート（順序ゆれの畳み込み）
        if let items = components.queryItems {
            let kept = items
                .filter { item in
                    let name = item.name.lowercased()
                    return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
                }
                .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            components.queryItems = kept.isEmpty ? nil : kept
        }

        // 末尾スラッシュの畳み込み（ルートパスは除く）
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        if components.path.isEmpty {
            components.path = "/"
        }

        return components.string
    }
}
