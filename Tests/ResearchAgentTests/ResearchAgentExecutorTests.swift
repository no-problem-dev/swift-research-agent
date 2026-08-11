import A2ACore
import A2AServer
import AgentRuntime
import Foundation
import LLMAgentStep
import LLMClient
import LLMTool
import ResearchStore
import Testing

@testable import ResearchAgent

private enum MockError: Error { case unused }

/// Answers with the same text every time, and counts how many times it was asked.
///
/// The text is the point: it cites a URL the ledger has never seen, so every attempt is one the
/// citation gate must reject.
private struct ScriptedClient: AgentCapableClient {
    typealias Model = String
    let replyText: String
    let calls: CallCounter

    func executeAgentStep(
        messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet,
        toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode,
        reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy
    ) async throws -> LLMResponse {
        await calls.count()
        return LLMResponse(
            content: [.text(replyText)], model: "mock",
            usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn
        )
    }

    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

private actor CallCounter {
    private(set) var total = 0
    func count() { total += 1 }
}

/// What the caller of one task actually sees: the states it passed through and the artifacts it
/// published.
private struct TaskOutcome {
    let states: [TaskState]
    let artifacts: [Artifact]
    let messages: [String]

    var terminalState: TaskState? { states.last }
    /// A completed task carrying an answer — what a consumer would treat as a verified result.
    var isCleanCompletion: Bool { terminalState == .completed && !artifacts.isEmpty }
}

/// Runs one task to its terminal state and collects everything published on the way.
private func runTask(
    replyText: String,
    registry: SourceRegistry,
    maxRetries: Int,
    calls: CallCounter,
    history: any AgentHistoryStore
) async throws -> TaskOutcome {
    let executor = ResearchAgentExecutor(
        client: ScriptedClient(replyText: replyText, calls: calls),
        model: "mock",
        tools: ToolSet(),
        systemPrompt: nil,
        registry: registry,
        maxRetries: maxRetries,
        cachePolicy: .implicit,
        history: history
    )
    let queue = EventQueue()
    let context = RequestContext(
        message: Message(messageId: MessageID(UUID().uuidString), role: .user, parts: [.text("調べて")]),
        taskId: TaskID("t1"),
        contextId: ContextID("c1")
    )

    let collected = Task { () -> [StreamResponse] in
        var events: [StreamResponse] = []
        for await event in await queue.tap() { events.append(event) }
        return events
    }
    await Task.yield()

    try await executor.execute(context, eventQueue: queue)
    await queue.close()
    let events = await collected.value

    return TaskOutcome(
        states: events.compactMap { if case .statusUpdate(let update) = $0 { return update.status.state } else { return nil } },
        artifacts: events.compactMap { if case .artifactUpdate(let update) = $0 { return update.artifact } else { return nil } },
        messages: events.compactMap { if case .statusUpdate(let update) = $0 { return update.status.message } else { return nil } }
            .flatMap { $0.parts.compactMap(\.text) }
    )
}

@Suite("ResearchAgentExecutor citation gate")
struct ResearchAgentExecutorTests {
    /// Cites a page the ledger has never seen — the fabricated-source case the gate exists for.
    private let badAnswer = "結論です。出典: https://example.com/never-fetched"

    @Test("maxRetries: 0 でも検査は走る（1 回だけ実行し、検証する）")
    func zeroRetriesStillValidates() async throws {
        let calls = CallCounter()
        let history = InMemoryAgentHistoryStore()
        let outcome = try await runTask(
            replyText: badAnswer, registry: SourceRegistry(), maxRetries: 0, calls: calls, history: history
        )

        #expect(!outcome.isCleanCompletion)
        #expect(outcome.terminalState == .failed)
        #expect(outcome.artifacts.isEmpty)
        // 1 回実行して 1 回検証する。再試行は 0 回。
        #expect(await calls.total == 1)
        // 検証を通っていない回答を履歴に残さない（次のタスクの前提になってしまう）
        #expect(await history.history(for: "c1").isEmpty)
    }

    @Test("最終試行が不合格なら、そのまま完了させない")
    func finalAttemptIsValidated() async throws {
        let calls = CallCounter()
        let history = InMemoryAgentHistoryStore()
        let outcome = try await runTask(
            replyText: badAnswer, registry: SourceRegistry(), maxRetries: 2, calls: calls, history: history
        )

        #expect(!outcome.isCleanCompletion)
        #expect(outcome.terminalState == .failed)
        #expect(outcome.artifacts.isEmpty)
        // 初回 + 是正 2 回。最後の 1 回も検査対象。
        #expect(await calls.total == 3)
        #expect(await history.history(for: "c1").isEmpty)
        // 何が駄目だったかは呼び出し側に見える
        #expect(outcome.messages.contains { $0.contains("does not appear") })
    }

    @Test("fetch 済みを引用した回答は完了する")
    func validAnswerCompletes() async throws {
        let registry = SourceRegistry()
        await registry.registerFetch(url: "https://example.com/page", title: "P", content: "body")
        let calls = CallCounter()
        let history = InMemoryAgentHistoryStore()
        let outcome = try await runTask(
            replyText: "結論です。出典: https://example.com/page",
            registry: registry, maxRetries: 0, calls: calls, history: history
        )

        #expect(outcome.isCleanCompletion)
        #expect(outcome.terminalState == .completed)
        #expect(outcome.artifacts.first?.parts.first?.text == "結論です。出典: https://example.com/page")
        #expect(await calls.total == 1)
        #expect(await history.history(for: "c1").count == 2)
    }
}
