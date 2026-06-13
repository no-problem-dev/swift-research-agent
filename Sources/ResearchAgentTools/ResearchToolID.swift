/// researcher のツール ID 一覧（SSOT）。
///
/// ホストはこの ID でツールの有効/無効を選び、同じセットを
/// `ResearchToolKit.tools(enabled:)` と `ResearcherAgent.systemPrompt(tools:)` /
/// `ResearcherAgent.description(tools:)` の全てへ渡す —
/// ツール一式・プロンプトの言及・委譲ルーティングの自己記述が常に一致する。
/// 表示用コピー（日本語要約など）はホスト UI 層が所有する。
public enum ResearchToolID: String, CaseIterable, Codable, Hashable, Sendable {
    case webSearch = "web_search"
    case fetch = "fetch"

    /// 無効化できないツール。fetch は出典検証ゲート（ResearchCitationGate）の
    /// 照合材料（fetch 済み本文）を台帳へ記帳する唯一の経路なので、外すと
    /// 「引用可能な出典」が存在できなくなる。
    public var isCore: Bool {
        self == .fetch
    }

    /// 動作に Web 検索プロバイダ（Serper 等）が要るツール。
    /// プロバイダ未構成なら enabled に含めても提供されない。
    public var requiresSearchProvider: Bool {
        self == .webSearch
    }

    /// 無効化できないコアツールのセット。
    public static let coreTools: Set<ResearchToolID> = Set(allCases.filter(\.isCore))

    /// 全ツールのセット（デフォルト = 全部オン）。
    public static let allTools: Set<ResearchToolID> = Set(allCases)
}
