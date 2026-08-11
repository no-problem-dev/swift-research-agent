import A2ACore
import A2AServer
import AgentLoopKit
import AgentRuntime
import Foundation
import LLMClient
import LLMTool
import LLMAgentStep
import ResearchStore

/// Runs the researcher loop and re-prompts the model when its citations do not check out.
///
/// Once the loop produces an answer, every URL in it is matched against this task's ledger.
/// Violations become a corrective user turn and the loop runs again, up to `maxRetries` times.
/// The retries are invisible from the outside: the caller sees one task that took longer.
///
/// Every attempt is checked, the last one included, so `maxRetries: 0` means one attempt that is
/// still validated. An answer that never satisfies the gate is never completed: once the retries
/// are spent the task fails, carrying the violations and the rejected text, so nothing downstream
/// can mistake it for a checked answer.
///
/// A completed task therefore always passed the gate, and carries one text artifact plus metadata:
/// token usage under `llm.usage`, and the cited sources as JSON under `research.references`.
public struct ResearchAgentExecutor<Client: AgentCapableClient>: AgentExecutor where Client.Model: Sendable {
    /// Artifact metadata key carrying the cited sources.
    ///
    /// The value is a JSON array of `SourceRecord` with snake_case keys, so a consumer can render
    /// references without parsing them back out of the answer text.
    public static var referencesMetadataKey: String { "research.references" }

    let client: Client
    let model: Client.Model
    let tools: ToolSet
    let systemPrompt: SystemPrompt?
    let maxSteps: Int
    let maxTokens: Int?
    /// Source ledger; must be the same instance the tool kit writes to, or every citation fails.
    let registry: SourceRegistry
    /// Corrective retries the gate gets after a failed check. `0` still validates the one attempt.
    let maxRetries: Int
    let cachePolicy: PromptCachePolicy
    /// Receives the system prompt the loop actually rendered — once per task, even across retries.
    let onSystemPrompt: (@Sendable (String) async -> Void)?
    /// Receives usage for each individual LLM call (call number, usage, model ID).
    ///
    /// The usage reported for the task as a whole is the sum over every call, so reading it as
    /// "the prompt was this big" is wrong; subscribe here when the per-call numbers matter.
    let onUsage: (@Sendable (_ call: Int, _ usage: TokenUsage, _ model: String) async -> Void)?
    /// History carried across tasks in the same context.
    ///
    /// This executor writes only the user input and the final answer; the tool transcript is not
    /// carried over.
    let history: any AgentHistoryStore

    /// Creates an executor bound to one task's source ledger.
    ///
    /// - Parameters:
    ///   - client: Client used for the LLM calls.
    ///   - model: Model identifier to call.
    ///   - tools: Tools the loop may call. Give it the same set the prompt was built from.
    ///   - systemPrompt: System prompt, or `nil` for the provider default.
    ///   - maxSteps: Upper bound on loop steps within one attempt (default: 16).
    ///   - maxTokens: Output token cap per LLM call, or `nil` for the provider default.
    ///   - registry: Source ledger. Must be the instance the tool kit records into, otherwise
    ///     every citation looks fabricated.
    ///   - maxRetries: Corrective retries after a failed citation check (default: 2). `0` means one
    ///     attempt, still checked; spending them all without passing fails the task.
    ///   - cachePolicy: Caching of the system prompt and tool declarations.
    ///   - onSystemPrompt: Receives the rendered system prompt, once per task.
    ///   - onUsage: Receives usage per LLM call, including calls made during corrective retries.
    ///   - history: Store for history across tasks in this context. Only the user input and the
    ///     final answer are written to it.
    public init(
        client: Client,
        model: Client.Model,
        tools: ToolSet,
        systemPrompt: SystemPrompt?,
        maxSteps: Int = 16,
        maxTokens: Int? = nil,
        registry: SourceRegistry,
        maxRetries: Int = 2,
        cachePolicy: PromptCachePolicy,
        onSystemPrompt: (@Sendable (String) async -> Void)? = nil,
        onUsage: (@Sendable (_ call: Int, _ usage: TokenUsage, _ model: String) async -> Void)? = nil,
        history: any AgentHistoryStore
    ) {
        self.client = client
        self.model = model
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.maxSteps = maxSteps
        self.maxTokens = maxTokens
        self.registry = registry
        self.maxRetries = maxRetries
        self.cachePolicy = cachePolicy
        self.onSystemPrompt = onSystemPrompt
        self.onUsage = onUsage
        self.history = history
    }

    /// Runs one task: agent loop, citation check, corrective retries, then a single artifact — or a
    /// failed task when the citations never check out.
    ///
    /// Thinking text and tool names are streamed as working status; the answer text is not
    /// streamed. Cancellation propagates to the caller. Any other error is reported as a failed
    /// task and swallowed rather than rethrown, so this returns normally either way.
    public func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()

        // usage (metrics) and systemPrompt (debug) arrive on the telemetry sideband rather than as
        // semantic events. The state lives in an actor because it is aggregated across retries.
        let telemetryState = ResearchTelemetryState()
        let onSystemPrompt = self.onSystemPrompt
        let onUsage = self.onUsage
        let loop = AgentLoop(
            client: client,
            model: model,
            tools: tools,
            systemPrompt: systemPrompt,
            maxSteps: maxSteps,
            maxTokens: maxTokens,
            cachePolicy: cachePolicy,
            telemetry: { telemetry in
                switch telemetry {
                case .usage(let usage, let model):
                    let calls = await telemetryState.addUsage(usage)
                    await onUsage?(calls, usage, model)
                case .systemPrompt(let rendered):
                    // The rendered prompt is identical on every retry, so emit it once
                    if await telemetryState.shouldEmitSystemPrompt() { await onSystemPrompt?(rendered) }
                case .validationFailed:
                    break
                }
            }
        )

        let contextId = context.contextId.rawValue
        let userInput = context.userInput()
        let priorHistory = await history.history(for: contextId)
        var messages = priorHistory + [.user(userInput)]
        var attempt = 0

        do {
            while true {
                var finalText = ""
                let transcript = try await loop.run(messages: messages) { event in
                    switch event {
                    case .thinkingDelta(let text):
                        if !text.isEmpty {
                            try await updater.updateStatus(.working, message: updater.makeAgentMessage([.text(text)]))
                        }
                    case .toolCall(_, let name, _):
                        try await updater.updateStatus(.working, message: updater.makeAgentMessage([.text("🔧 \(name)")]))
                    case .toolResult:
                        // The tools record their own sources in the ledger; nothing to intercept here
                        break
                    case .textDelta:
                        // The final text arrives with .completed. Deltas are not surfaced: streaming
                        // them alongside thinkingDelta interleaves two texts in the consumer's view.
                        break
                    case .toolApprovalRequired(_, let name, _, _):
                        // This worker runs unattended, so there is no way to approve a tool. The loop
                        // returns without running it once approval is requested, and staying silent
                        // here would look like the answer simply came back empty. Say why.
                        try await updater.updateStatus(.working, message: updater.makeAgentMessage(
                            [.text("承認が必要なツール「\(name)」が呼ばれたため中断した（無人実行では承認できない）")]))
                    case .inputRequired(let question):
                        try await updater.requiresInput(message: updater.makeAgentMessage([.text(question)]))
                    case .completed(let text):
                        finalText = text
                    }
                }

                let issues = await ResearchCitationGate.validate(text: finalText, registry: registry)
                if issues.isEmpty {
                    // Store the exchange as an input/answer pair. Carrying the whole transcript,
                    // thousands of tokens of fetched page text included, would grow this context
                    // linearly with every task. The evidence for citations stays in the ledger, which
                    // still holds pages fetched by earlier tasks, so the gate keeps working.
                    await history.save(priorHistory + [.user(userInput), .assistant(finalText)], for: contextId)
                    await updater.addArtifact(
                        [.text(finalText)], name: "response", metadata: await artifactMetadata(finalText: finalText, usage: await telemetryState.total)
                    )
                    try await updater.complete()
                    return
                }

                guard attempt < maxRetries else {
                    // The retry budget is spent and the citations still do not hold up. Completing
                    // here would hand the caller an answer that looks checked, which is the one
                    // thing this executor exists to prevent — so the task fails, carrying the
                    // violations and the rejected text so nothing is lost and nothing is disguised.
                    try await updater.fail(message: updater.makeAgentMessage([
                        .text("出典検証を通らなかった（\(issues.count) 件）:\n" + issues.map { "- \($0)" }.joined(separator: "\n")),
                        .text(finalText),
                    ]))
                    return
                }

                attempt += 1
                try await updater.updateStatus(
                    .working,
                    message: updater.makeAgentMessage([.text("🔎 出典検証 NG (\(issues.count) 件) → 修正 \(attempt)/\(maxRetries)")])
                )
                messages = transcript + [.user(ResearchCitationGate.corrective(issues: issues))]
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? await updater.fail(message: updater.makeAgentMessage([.text("\(error)")]))
        }
    }

    public func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.cancel()
    }

    // MARK: - Artifact Metadata

    /// Packs token usage (under "llm.usage", the key UsageMetadata uses) and the cited sources
    /// into the artifact's metadata. Returns `nil` when there is neither.
    private func artifactMetadata(finalText: String, usage: TokenUsage?) async -> A2AMetadata? {
        var metadata: A2AMetadata = [:]
        if let usage,
           let data = try? JSONEncoder().encode(usage),
           let json = String(data: data, encoding: .utf8) {
            metadata["llm.usage"] = .string(json)
        }
        let cited = ResearchCitationGate.urls(in: finalText)
        let references = await registry.references(citedURLs: cited)
        if !references.isEmpty,
           let data = try? JSONEncoder().encode(references),
           let json = String(data: data, encoding: .utf8) {
            metadata[Self.referencesMetadataKey] = .string(json)
        }
        return metadata.isEmpty ? nil : metadata
    }
}

/// State behind the `@Sendable` telemetry sink, shared across corrective retries.
///
/// Totals usage, counts LLM calls, and remembers whether the system prompt hook has already fired.
private actor ResearchTelemetryState {
    private(set) var total: TokenUsage?
    private var calls = 0
    private var emittedSystemPrompt = false

    /// Adds a usage sample and returns how many LLM calls have been counted so far.
    func addUsage(_ usage: TokenUsage) -> Int {
        total = total?.adding(usage) ?? usage
        calls += 1
        return calls
    }

    /// Returns `true` for the first caller only.
    func shouldEmitSystemPrompt() -> Bool {
        if emittedSystemPrompt { return false }
        emittedSystemPrompt = true
        return true
    }
}
