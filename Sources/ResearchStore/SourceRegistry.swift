import Foundation

// MARK: - SourceRecord

/// タスク中に観測した 1 ソースの記録。
public struct SourceRecord: Sendable, Codable, Equatable {
    /// 正規化済み URL（台帳キー）
    public let normalizedURL: String
    /// 最初に観測した元の表記
    public let url: String
    /// ページタイトル（検索結果または fetch 時に取得、未取得なら `nil`）
    public var title: String?
    /// 検索結果のスニペット（検索経由で観測した場合）
    public var snippet: String?
    /// 公開日など、検索プロバイダが返した日付文字列
    public var date: String?
    /// 検索結果での順位（1 始まり）
    public var position: Int?
    /// fetch に成功して本文を読んだか。引用可否の判定基準
    /// （fetch 成功 = 実在 + 到達可能 + 内容を確認済み）。
    public var fetched: Bool

    enum CodingKeys: String, CodingKey {
        case normalizedURL = "normalized_url"
        case url, title, snippet, date, position, fetched
    }
}

// MARK: - SourceRegistry

/// タスク中に観測した全ソースの台帳（SSOT）。
///
/// ツール（web_search / fetch）が観測のたびに記帳し、出典検証ゲートが
/// 「引用された URL が台帳に存在し fetch 済みか」を照合する。
/// MediaSessionStore と同じく、ツールに注入されるセッションスコープの actor。
///
/// 責務は記帳と照会まで — 検証の判断（違反かどうか）はゲート側が行う。
public actor SourceRegistry {
    private var records: [String: SourceRecord] = [:]
    /// fetch 済み本文（正規化 URL → 本文）。逐語引用の照合材料。
    private var contents: [String: String] = [:]
    /// 本文保持の上限（1 ソースあたり）。照合材料として十分な範囲でメモリを抑える
    private let maxContentLength: Int

    /// 台帳を作成する。
    ///
    /// - Parameter maxContentLength: 1 ソースあたりの本文保持上限（文字数、デフォルト: 200,000）。
    ///   ページネーション再取得でより長い本文が得られた場合は更新する。
    public init(maxContentLength: Int = 200_000) {
        self.maxContentLength = maxContentLength
    }

    // MARK: - 記帳

    /// 検索結果の記帳。既知 URL ならメタデータを補完する（fetched は降格させない）。
    public func registerSearchResult(url: String, title: String?, snippet: String?, date: String? = nil, position: Int? = nil) {
        guard let key = URLNormalization.normalize(url) else { return }
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
    }

    /// fetch 成功の記帳。本文を照合材料として保持する。
    public func registerFetch(url: String, title: String?, content: String) {
        guard let key = URLNormalization.normalize(url) else { return }
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
        // ページネーション再取得の追記は重複させず、より長い本文を採用する
        let capped = String(content.prefix(maxContentLength))
        if let stored = contents[key], stored.count >= capped.count { return }
        contents[key] = capped
    }

    // MARK: - 照会

    /// 引用 URL（表記ゆれ込み）に対応する記録を引く。
    public func record(citing url: String) -> SourceRecord? {
        guard let key = URLNormalization.normalize(url) else { return nil }
        return records[key]
    }

    /// fetch 済み本文を引く。
    public func content(citing url: String) -> String? {
        guard let key = URLNormalization.normalize(url) else { return nil }
        return contents[key]
    }

    /// 引用された URL 群に対応する記録（References の構造化出力用）。
    public func references(citedURLs: [String]) -> [SourceRecord] {
        var seen = Set<String>()
        return citedURLs.compactMap { url in
            guard let key = URLNormalization.normalize(url),
                  let record = records[key],
                  seen.insert(key).inserted else { return nil }
            return record
        }
    }

    /// 台帳に記録された全ソースの一覧。
    public var allRecords: [SourceRecord] {
        Array(records.values)
    }
}
