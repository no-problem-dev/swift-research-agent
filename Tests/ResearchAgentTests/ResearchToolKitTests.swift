import Testing
@testable import ResearchAgentTools
import ResearchAgent
import ResearchStore

@Suite("ResearchToolKit tool selection")
struct ResearchToolKitTests {
    private struct StubSearchProvider: WebSearchProvider {
        func search(query: String, maxResults: Int) async throws -> [WebSearchResult] { [] }
    }

    @Test func toolCompositionFollowsConfiguration() {
        let bare = ResearchToolKit(registry: SourceRegistry())
        #expect(bare.tools.map(\.toolName) == ["fetch"])
        #expect(bare.availableToolIDs == [.fetch])

        let withSearch = ResearchToolKit(registry: SourceRegistry(), searchProvider: StubSearchProvider())
        #expect(withSearch.tools.map(\.toolName) == ["web_search", "fetch"])
        #expect(withSearch.availableToolIDs == [.webSearch, .fetch])
    }

    @Test func toolSelectionKeepsCoreAndDropsDisabled() {
        let kit = ResearchToolKit(registry: SourceRegistry(), searchProvider: StubSearchProvider())
        // Disabling web_search leaves fetch.
        #expect(kit.tools(enabled: [.fetch]).map(\.toolName) == ["fetch"])
        // Even with everything switched off, the core tool stays.
        #expect(kit.tools(enabled: []).map(\.toolName) == ["fetch"])
        // Without a provider, web_search is absent even when enabled.
        let bare = ResearchToolKit(registry: SourceRegistry())
        #expect(bare.tools(enabled: [.webSearch, .fetch]).map(\.toolName) == ["fetch"])
    }

    @Test func systemPromptMentionsOnlyEnabledTools() {
        let full = ResearcherAgent.systemPrompt().render()
        #expect(full.contains("web_search / fetch"))
        let fetchOnly = ResearcherAgent.systemPrompt(tools: [.fetch]).render()
        #expect(!fetchOnly.contains("web_search"))
        #expect(fetchOnly.contains("fetch"))
    }

    @Test func descriptionFollowsEnabledTools() {
        #expect(ResearcherAgent.description().contains("Searches the web"))
        #expect(!ResearcherAgent.description(tools: [.fetch]).contains("Searches the web"))
    }
}
