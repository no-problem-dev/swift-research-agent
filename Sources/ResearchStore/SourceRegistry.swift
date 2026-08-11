import Foundation

// MARK: - SourceKey

/// The key a URL is filed under in the ledger, and whether normalization produced it.
///
/// Every registration and every lookup goes through this, so the two can never disagree about
/// where a source lives.
public enum SourceKey: Sendable, Hashable {
    /// The URL normalized. Spellings of the same page — `www.`, tracking parameters, fragment,
    /// trailing slash — all fold into this one key.
    case canonical(String)
    /// The URL exactly as given, used when it cannot be normalized (anything `URLNormalization`
    /// cannot parse as http/https).
    ///
    /// The source is still recorded and still citable, but under this spelling alone: a citation
    /// written differently will not fold into it.
    case verbatim(String)

    /// The string the ledger files this source under.
    public var value: String {
        switch self {
        case .canonical(let value), .verbatim(let value): return value
        }
    }

    /// Whether normalization produced this key.
    public var isCanonical: Bool {
        if case .canonical = self { return true }
        return false
    }

    /// Derives the ledger key for a URL. Never fails: normalization is an improvement on the key,
    /// not a condition for having one.
    public init(url: String) {
        if let normalized = URLNormalization.normalize(url) {
            self = .canonical(normalized)
        } else {
            self = .verbatim(url.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

// MARK: - SourceRecord

/// One URL observed during a research task, and how far verification of it got.
public struct SourceRecord: Sendable, Codable, Equatable {
    /// Ledger key: this URL after normalization, or the URL as given when it does not normalize.
    /// Either way it is what every lookup matches on.
    public let normalizedURL: String
    /// The URL as first observed; later spellings of the same page do not replace it.
    public let url: String
    /// Title from the search result, replaced by the page's own title once a fetch succeeds.
    public var title: String?
    /// Snippet from the search result, set only when the URL was seen in search results.
    ///
    /// A fetch never fills this in, and a snippet alone is not enough to cite the page.
    public var snippet: String?
    /// Date string exactly as the search provider spelled it — unparsed, format varies per provider.
    public var date: String?
    /// Rank within the search results, 1-based; `nil` when the provider reports no rank.
    public var position: Int?
    /// Whether a fetch of this URL succeeded and stored its body.
    ///
    /// The citation gate rejects every cited URL whose record has this `false`, so a page seen
    /// only in search results cannot be cited.
    public var fetched: Bool

    enum CodingKeys: String, CodingKey {
        case normalizedURL = "normalized_url"
        case url, title, snippet, date, position, fetched
    }
}

// MARK: - SourceRegistry

/// In-memory ledger of every source observed during one research task.
///
/// The tools (`web_search` / `fetch`) write to it as they observe URLs, and the citation gate
/// reads it to decide whether a cited URL was really fetched. Create one per task and hand the
/// same instance to both, or the gate has nothing to match against.
///
/// Registration and lookup both go through `SourceKey`, so `www.`, tracking parameters, fragments
/// and trailing slashes all resolve to one record. A URL that fails to normalize is still recorded
/// — under its own spelling, and the registration call says so — because dropping a fetch that
/// succeeded would make a legitimate citation of it read as fabricated.
///
/// Nothing is persisted and nothing is evicted — the ledger lives exactly as long as the actor.
/// Stored bodies are capped per source, but the number of sources is not, so a long task grows
/// monotonically.
///
/// It records and answers questions; deciding what counts as a violation belongs to the gate.
public actor SourceRegistry {
    private var records: [String: SourceRecord] = [:]
    /// Fetched page bodies, keyed by normalized URL.
    ///
    /// The gate never reads them; they exist for callers that want to check a quote themselves.
    private var contents: [String: String] = [:]
    /// Per-source cap on stored body length, so one huge page cannot dominate memory.
    private let maxContentLength: Int

    /// Creates an empty ledger.
    ///
    /// - Parameter maxContentLength: Characters kept per source (default: 200,000). Longer bodies
    ///   are truncated before storage, and a paginated re-fetch that yields more text replaces the
    ///   shorter copy.
    public init(maxContentLength: Int = 200_000) {
        self.maxContentLength = maxContentLength
    }

    // MARK: - Registration

    /// Records a search hit, filling in only the fields the ledger is still missing.
    ///
    /// An existing record keeps the title, snippet, date and position it already had, and
    /// `fetched` is never demoted — a fetched page that shows up again in later search results
    /// stays citable.
    ///
    /// - Returns: The key the hit was filed under. A `.verbatim` key means the URL could not be
    ///   normalized, so only this exact spelling of it will resolve to the record.
    @discardableResult
    public func registerSearchResult(url: String, title: String?, snippet: String?, date: String? = nil, position: Int? = nil) -> SourceKey {
        let sourceKey = SourceKey(url: url)
        let key = sourceKey.value
        if var existing = records[key] {
            if existing.title == nil { existing.title = title }
            if existing.snippet == nil { existing.snippet = snippet }
            if existing.date == nil { existing.date = date }
            if existing.position == nil { existing.position = position }
            records[key] = existing
        } else {
            records[key] = SourceRecord(
                normalizedURL: key, url: url, title: title,
                snippet: snippet, date: date, position: position, fetched: false
            )
        }
        return sourceKey
    }

    /// Records a successful fetch, making the URL citable and storing its body.
    ///
    /// Sets `fetched` to `true`, overwrites the title when one is given, and keeps whichever body
    /// is longer, so a paginated re-fetch never shortens what is already stored. The body is
    /// truncated to the per-source cap first.
    ///
    /// - Returns: The key the page was filed under. A `.verbatim` key means the URL could not be
    ///   normalized: the page is on the ledger and citable, but only under this exact spelling.
    ///   The fetch itself is never discarded — a page that was really opened has to stay citable,
    ///   or the gate reports the ledger's own gap as the model fabricating a source.
    @discardableResult
    public func registerFetch(url: String, title: String?, content: String) -> SourceKey {
        let sourceKey = SourceKey(url: url)
        let key = sourceKey.value
        if var existing = records[key] {
            existing.fetched = true
            if let title { existing.title = title }
            records[key] = existing
        } else {
            records[key] = SourceRecord(
                normalizedURL: key, url: url, title: title,
                snippet: nil, date: nil, position: nil, fetched: true
            )
        }
        // Keep the longer body rather than appending, so a paginated re-fetch cannot duplicate text
        let capped = String(content.prefix(maxContentLength))
        if let stored = contents[key], stored.count >= capped.count { return sourceKey }
        contents[key] = capped
        return sourceKey
    }

    // MARK: - Lookup

    /// Looks up the record for a cited URL, matching on the same key registration used.
    ///
    /// - Returns: `nil` when the URL was never observed in this task. A URL that does not
    ///   normalize resolves to the record registered under that exact spelling, if there is one.
    public func record(citing url: String) -> SourceRecord? {
        records[SourceKey(url: url).value]
    }

    /// Returns the stored body of a fetched page, for callers that want to check a quote against it.
    ///
    /// Nothing in this package reads it: the citation gate matches URLs and never compares text.
    /// `nil` when the URL was never fetched.
    public func content(citing url: String) -> String? {
        contents[SourceKey(url: url).value]
    }

    /// Resolves cited URLs to their records, in citation order, for a structured references list.
    ///
    /// URLs that resolve to the same key appear once, and URLs absent from the ledger are
    /// dropped silently, so the result can be shorter than the input. Records that were only ever
    /// search hits are included: appearing here does not mean the URL passed the citation gate.
    public func references(citedURLs: [String]) -> [SourceRecord] {
        var seen = Set<String>()
        return citedURLs.compactMap { url in
            let key = SourceKey(url: url).value
            guard let record = records[key],
                  seen.insert(key).inserted else { return nil }
            return record
        }
    }

    /// Every record in the ledger, in no particular order.
    public var allRecords: [SourceRecord] {
        Array(records.values)
    }
}
