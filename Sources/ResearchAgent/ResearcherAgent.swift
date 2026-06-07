import A2ACore
import Foundation
import LLMClient

/// researcher エージェントの自己記述（system prompt / AgentCard）。
///
/// ツールの使い方はツール定義側が説明するため、system prompt は役割と出力制約だけを持つ。
public enum ResearcherAgent {
    public static let defaultName = "researcher"
    public static let defaultDescription =
        "Web research agent. Searches the web, fetches pages, and answers with verified, cited sources."

    /// researcher の system prompt。
    ///
    /// 役割と出典規約（ResearchCitationGate の検証基準と対）だけの最小構成。
    /// ツールの使い方・検索結果の扱いはツール定義側が説明するため、ここでは繰り返さない。
    public static func systemPrompt(outputConstraint: String = "Reply concisely in Japanese.") -> SystemPrompt {
        SystemPrompt {
            PromptComponent.role(
                "Research assistant. Complete the assigned task using web_search / fetch when facts or sources are needed."
            )
            PromptComponent.constraint(
                "Base every claim and named entity on page content fetched this session, and cite the fetched source URLs. Never cite from memory or from search snippets alone."
            )
            PromptComponent.outputConstraint(outputConstraint)
        }
    }

    /// researcher の AgentCard。
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
