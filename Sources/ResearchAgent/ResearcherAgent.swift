import A2ACore
import Foundation
import LLMClient
import ResearchAgentTools

/// How the researcher worker describes itself: system prompt, delegation blurb and agent card.
///
/// Every piece is derived from the same enabled-tool set, so the prompt never mentions a tool the
/// worker was not given and an orchestrator is never told it can search when no search provider is
/// configured. How the tools work is left to the tool definitions; the prompt carries only the
/// role, the citation rule and the output constraint.
public enum ResearcherAgent {
    public static let defaultName = "researcher"

    /// Delegation description for the full tool set.
    ///
    /// Use `description(tools:)` instead when the worker runs with tools disabled: this text
    /// advertises web search.
    public static var defaultDescription: String { description() }

    /// Builds the description an orchestrator routes on, from the tools the worker will hold.
    ///
    /// Pass the same set given to `ResearchToolKit.tools(enabled:)` and `systemPrompt(tools:)`, so
    /// what the host is told the worker can do matches what it can actually do. Without
    /// `web_search`, the text promises only fetching URLs it is handed or already knows.
    public static func description(tools enabled: Set<ResearchToolID> = ResearchToolID.allTools) -> String {
        enabled.contains(.webSearch)
            ? "Web research agent. Searches the web, fetches pages, and answers with verified, cited sources."
            : "Web research agent. Fetches pages from given or known URLs and answers with verified, cited sources."
    }

    /// Builds the researcher system prompt from the tools the worker will hold.
    ///
    /// The prompt states the role, the citation rule the gate enforces (base claims on pages
    /// fetched this session and cite them; never cite from memory or from snippets) and one output
    /// constraint. Tool usage is described by the tool definitions and not repeated here.
    ///
    /// - Parameters:
    ///   - outputConstraint: Instruction about the form and language of the answer. The default
    ///     asks for concise Japanese, so override it for any other language.
    ///   - enabled: Tools the worker will actually be given; only these are named in the role line.
    public static func systemPrompt(
        outputConstraint: String = "Reply concisely in Japanese.",
        tools enabled: Set<ResearchToolID> = ResearchToolID.allTools
    ) -> SystemPrompt {
        let toolMention = enabled.contains(.webSearch) ? "web_search / fetch" : "fetch"
        return SystemPrompt {
            PromptComponent.role(
                "Research assistant. Complete the assigned task using \(toolMention) when facts or sources are needed."
            )
            PromptComponent.constraint(
                "Base every claim and named entity on page content fetched this session, and cite the fetched source URLs. Never cite from memory or from search snippets alone."
            )
            PromptComponent.outputConstraint(outputConstraint)
        }
    }

    /// Builds the researcher's agent card, describing an in-process worker with streaming on.
    ///
    /// Pass a `description` built from the same tool set the worker runs with, so routing is not
    /// told about a capability the worker does not have.
    public static func card(
        name: String = defaultName,
        description: String = defaultDescription,
        interfaceURL: String = "inprocess://researcher",
        version: String = "1.0.0"
    ) -> AgentCard {
        AgentCard(
            name: name,
            description: description,
            supportedInterfaces: [AgentInterface(url: interfaceURL, protocolBinding: "InProcess")],
            version: version,
            capabilities: AgentCapabilities(streaming: true)
        )
    }
}
