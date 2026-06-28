# ``ResearchAgent``

出典検証ゲート付き Web リサーチエージェント。`AgentExecutor` を実装し、LLM が引用した URL が実際にフェッチ済みかをセッションスコープの台帳で照合する。

## Overview

`ResearchAgent` は `swift-research-agent` パッケージの最上位レイヤーです。3 つの責務を統合します。

- **エージェント自己記述** — `ResearcherAgent` が system prompt・AgentCard・委譲説明を有効ツール構成から組み立てる
- **実行ループ** — `ResearchAgentExecutor` が `AgentLoop` を駆動し、完了テキストを `ResearchCitationGate` に掛けて是正リトライを行う
- **出典検証ゲート** — `ResearchCitationGate` が `SourceRegistry` と照合し、未フェッチ URL の引用を検出する

```swift
let registry = SourceRegistry()
let toolKit = ResearchToolKit.serper(registry: registry, apiKey: env("SERPER_KEY"), gl: "jp", hl: "ja")
let executor = ResearchAgentExecutor(
    client: anthropic,
    model: .claude_opus_4_5,
    tools: ToolSet { toolKit },
    systemPrompt: ResearcherAgent.systemPrompt(),
    registry: registry,
    cachePolicy: .none,
    history: InMemoryAgentHistory()
)
```

出典が `SourceRegistry` に記帳されていない URL、または `fetched == false` の URL を引用した回答は `maxRetries` 回まで自動是正されます。合格した回答のアーティファクトには `research.references` キーで引用出典の構造化データ（`[SourceRecord]` JSON）が付きます。

## Topics

### Essentials

- <doc:GettingStarted>

### エージェント組立

- ``ResearcherAgent``
- ``ResearchAgentExecutor``

### 出典検証

- ``ResearchCitationGate``
