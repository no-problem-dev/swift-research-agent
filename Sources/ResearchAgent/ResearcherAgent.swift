import A2ACore
import Foundation
import LLMClient
import ResearchAgentTools

/// researcher エージェントの自己記述（system prompt / AgentCard）。
///
/// ツールの使い方はツール定義側が説明するため、system prompt は役割と出力制約だけを持つ。
public enum ResearcherAgent {
    public static let defaultName = "researcher"

    /// オーケストレータが委譲判断に使う説明（全ツール構成のデフォルト）。
    public static var defaultDescription: String { description() }

    /// オーケストレータが委譲判断に使う説明を、有効ツール構成から組み立てる。
    /// `ResearchToolKit.tools(enabled:)` / `systemPrompt(tools:)` と同じセットを渡すこと —
    /// ホストが「できる」と聞かされた能力と実際の道具が一致する。
    public static func description(tools enabled: Set<ResearchToolID> = ResearchToolID.allTools) -> String {
        enabled.contains(.webSearch)
            ? "Web research agent. Searches the web, fetches pages, and answers with verified, cited sources."
            : "Web research agent. Fetches pages from given or known URLs and answers with verified, cited sources."
    }

    /// researcher の system prompt を有効ツール構成から組み立てる。
    ///
    /// 役割と出典規約（ResearchCitationGate の検証基準と対）だけの最小構成。
    /// ツールの使い方・検索結果の扱いはツール定義側が説明するため、ここでは繰り返さない。
    /// 役割行のツール言及は `ResearchToolKit.tools(enabled:)` と同じセットで剪定する —
    /// 持っていないツールへの言及がプロンプトに残らない。
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
