import Foundation

/// URL canonicalization that decides when two citations point at the same page.
///
/// Folds spellings that do not change which page is meant — tracking parameters, fragment,
/// `www.`, default port, scheme and host case, query order, trailing slash — into one ledger key,
/// so a citation written slightly differently from the fetched URL still matches. Rewrites that
/// could change the page are deliberately left alone: path case is preserved, and nothing is
/// resolved or redirected over the network.
public enum URLNormalization {
    /// Query parameters treated as tracking noise; `utm_*` is matched by prefix instead.
    private static let trackingParameters: Set<String> = [
        "gclid", "fbclid", "yclid", "msclkid", "dclid", "igshid", "twclid",
        "mc_cid", "mc_eid", "_ga", "_gl", "ref_src", "ref_url", "cmpid",
        "spm", "share_id", "xtor",
    ]

    /// Canonicalizes a URL into a ledger key.
    ///
    /// - Returns: `nil` for anything that is not parsable http or https — callers treat that as
    ///   "not a source" rather than as an error.
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

        // Drop www. and the scheme's default port
        if host.hasPrefix("www."), host.count > 4 {
            host = String(host.dropFirst(4))
        }
        components.host = host
        if let port = components.port,
           (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            components.port = nil
        }

        // A fragment only selects a position inside the page, so it is not part of page identity
        components.fragment = nil

        // Strip tracking parameters, then sort the rest so query order stops mattering
        if let items = components.queryItems {
            let kept = items
                .filter { item in
                    let name = item.name.lowercased()
                    return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
                }
                .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            components.queryItems = kept.isEmpty ? nil : kept
        }

        // Fold the trailing slash, except on the root path
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        if components.path.isEmpty {
            components.path = "/"
        }

        return components.string
    }
}
