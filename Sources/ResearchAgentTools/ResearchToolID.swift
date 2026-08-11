/// The tools a researcher worker can be given, named once for every layer that has to agree.
///
/// A host picks a set of these and passes the same set to the tool kit, the system prompt and the
/// delegation description, so the tools the worker holds, the tools the prompt talks about and the
/// capability the orchestrator routes on can never drift apart. Display copy for a UI is not here;
/// it belongs to the host.
public enum ResearchToolID: String, CaseIterable, Codable, Hashable, Sendable {
    case webSearch = "web_search"
    case fetch = "fetch"

    /// Whether the tool survives being switched off.
    ///
    /// Only `fetch` does. It is the one path that marks a URL fetched in the ledger, so removing it
    /// would leave no source that the citation gate can ever accept.
    public var isCore: Bool {
        self == .fetch
    }

    /// Whether the tool needs a configured search provider.
    ///
    /// Enabling one of these without a provider silently yields nothing: the tool is not offered.
    public var requiresSearchProvider: Bool {
        self == .webSearch
    }

    /// The tools that are always offered, whatever the caller enables.
    public static let coreTools: Set<ResearchToolID> = Set(allCases.filter(\.isCore))

    /// Every tool, which is the default configuration.
    public static let allTools: Set<ResearchToolID> = Set(allCases)
}
