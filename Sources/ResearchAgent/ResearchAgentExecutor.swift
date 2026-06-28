import AgentLoopKit
import AgentRuntime
import Foundation
import LLMClient
import LLMTool
import LLMAgentStep
import ResearchStore

/// researcher ワーカーの AgentExecutor。
///
/// AgentLoop を回し、完了テキストを ResearchCitationGate（SourceRegistry 照合）に掛け、
/// 違反があれば是正メッセージを積んで再ループする（上限到達時は劣化許容でそのまま出す）。
/// 検証ループは executor 内に閉じ、外からはワーカーの品質が上がっただけに見える。
///
/// 合格した回答には、引用された出典の構造化データを artifact metadata
/// `research.references` として添付する（A2A 境界で citation を構造のまま運ぶ契約）。
public struct ResearchAgentExecutor<Client: AgentCapableClient>: AgentExecutor where Client.Model: Sendable {
    /// artifact metadata に References を載せるキー。
    /// 値は `[SourceRecord]` の JSON 文字列（`SourceRecord.CodingKeys` 参照）。
    public static var referencesMetadataKey: String { "research.references" }

    let client: Client
    let model: Client.Model
    let tools: ToolSet
    let systemPrompt: SystemPrompt?
    let maxSteps: Int
    let maxTokens: Int?
    /// 観測ソースの台帳（ResearchToolKit と共有するセッションスコープの actor）
    let registry: SourceRegistry
    /// 出典検証の是正リトライ上限
    let maxRetries: Int
    let cachePolicy: PromptCachePolicy
    /// ループが実際にレンダリングした system prompt の観測フック（デバッグ計測用）。
    let onSystemPrompt: (@Sendable (String) async -> Void)?
    /// LLM 呼び出し 1 回ごとの usage 観測フック（呼び出し番号, usage, モデル ID）。
    /// 委譲結果の usage は全呼び出しの合算なので、「合算値 = プロンプトサイズ」の
    /// 誤読を防ぐにはこの per-call 計測を購読する。
    let onUsage: (@Sendable (_ call: Int, _ usage: TokenUsage, _ model: String) async -> Void)?
    /// ネイティブ会話履歴（tool call/result を型のまま保持）。
    let history: any AgentHistoryStore

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

    public func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()

        // usage（metrics）と systemPrompt（debug）は意味論イベントと別の telemetry 側帯で受ける。
        // 是正リトライを跨いで集計するため状態は actor に集約する。
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
                    // 是正リトライでも内容は不変なので 1 回だけ流す
                    if await telemetryState.shouldEmitSystemPrompt() { await onSystemPrompt?(rendered) }
                case .validationFailed:
                    break
                }
            }
        )

        let contextId = context.contextId.rawValue
        let userInput = context.getUserInput()
        let priorHistory = await history.history(for: contextId)
        var messages = priorHistory + [.user(userInput)]
        var attempt = 0

        do {
            while true {
                var finalText = ""
                let transcript = try await loop.run(messages: messages) { event in
                    switch event {
                    case .thinking(let text):
                        if !text.isEmpty {
                            try await updater.updateStatus(.working, message: updater.newAgentMessage([.text(text)]))
                        }
                    case .toolCall(_, let name):
                        try await updater.updateStatus(.working, message: updater.newAgentMessage([.text("🔧 \(name)")]))
                    case .toolResult:
                        // ソースの記帳はツール自身が SourceRegistry へ行う（傍受不要）
                        break
                    case .inputRequired(let question):
                        try await updater.requiresInput(message: updater.newAgentMessage([.text(question)]))
                    case .completed(let text):
                        finalText = text
                    }
                }

                let issues = attempt < maxRetries
                    ? await ResearchCitationGate.validate(text: finalText, registry: registry)
                    : []
                if issues.isEmpty {
                    // 履歴は「入力 + 最終回答」の要約ペアで保存する。全 transcript（fetch 本文
                    // 数千トークン込み)を持ち越すとタスクごとにコンテキストが線形成長するため。
                    // 出典の照合材料は SourceRegistry が保持しており、過去タスクで fetch 済みの
                    // URL は次タスクでも引用可能なまま — ゲートの検証は壊れない。
                    await history.save(priorHistory + [.user(userInput), .assistant(finalText)], for: contextId)
                    await updater.addArtifact(
                        [.text(finalText)], name: "response", metadata: await artifactMetadata(finalText: finalText, usage: await telemetryState.total)
                    )
                    try await updater.complete()
                    return
                }

                attempt += 1
                try await updater.updateStatus(
                    .working,
                    message: updater.newAgentMessage([.text("🔎 出典検証 NG (\(issues.count) 件) → 修正 \(attempt)/\(maxRetries)")])
                )
                messages = transcript + [.user(ResearchCitationGate.corrective(issues: issues))]
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? await updater.failed(message: updater.newAgentMessage([.text("\(error)")]))
        }
    }

    public func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.cancel()
    }

    // MARK: - Artifact Metadata

    /// usage（AgentRuntime の UsageMetadata と同じ key "llm.usage"）と References を artifact metadata で運ぶ。
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

/// telemetry sink（@Sendable）越しに usage 集計・LLM 呼び出し数・systemPrompt の一度きり発火を
/// 是正リトライを跨いで保持するスレッドセーフな状態。
private actor ResearchTelemetryState {
    private(set) var total: TokenUsage?
    private var calls = 0
    private var emittedSystemPrompt = false

    /// usage を加算し、累計の LLM 呼び出し回数を返す。
    func addUsage(_ usage: TokenUsage) -> Int {
        total = total?.adding(usage) ?? usage
        calls += 1
        return calls
    }

    /// systemPrompt をまだ流していなければ true を返し、以後は false（一度きり）。
    func shouldEmitSystemPrompt() -> Bool {
        if emittedSystemPrompt { return false }
        emittedSystemPrompt = true
        return true
    }
}
