# ``ResearchAgent``

出典検証ゲート付き Web リサーチエージェント。`AgentExecutor` を実装し、LLM が引用した URL が実際にフェッチ済みかをセッションスコープの台帳で照合する。

## Overview

`ResearchAgent` は `swift-research-agent` パッケージの最上位レイヤーだ。3 つの責務を統合する。

- **エージェント自己記述** — `ResearcherAgent` が system prompt・AgentCard・委譲説明を有効ツール構成から組み立てる
- **実行ループ** — `ResearchAgentExecutor` が `AgentLoop` を駆動し、完了テキストを `ResearchCitationGate` に掛けて是正リトライを行う
- **出典検証ゲート** — `ResearchCitationGate` が `SourceRegistry` と照合し、未フェッチ URL の引用を検出する

```swift
let registry = SourceRegistry()
let toolKit = ResearchToolKit.serper(registry: registry, apiKey: env("SERPER_KEY"), gl: "jp", hl: "ja")
let executor = ResearchAgentExecutor(
    client: anthropic,
    model: .claude_opus_4_5,
    tools: ToolSet { toolKit.tools(enabled: ResearchToolID.allTools) },
    systemPrompt: ResearcherAgent.systemPrompt(),
    registry: registry,
    cachePolicy: .implicit,
    history: InMemoryAgentHistory()
)
```

出典が `SourceRegistry` に記帳されていない URL、または `fetched == false` の URL を引用した回答は `maxRetries` 回まで自動是正される。合格した回答のアーティファクトには `research.references` キーで引用出典の構造化データ（`[SourceRecord]` JSON）が付く。

### 兄弟モジュールとの役割分担

このパッケージは 3 層構造で成り立つ。

**`ResearchStore`** はパッケージ最下位の台帳層だ。`SourceRegistry` actor がタスク中に観測した全 URL の記録（`SourceRecord`）を保持する。UI・LLM・ネットワークに依存せず、単独でインポートして使える。検索結果（`fetched == false`）と fetch 成功（`fetched == true`）を区別して記帳し、引用可否の判定根拠を提供する。また `URLNormalization` がトラッキングパラメータ・フラグメント・`www.` 等の表記ゆれを畳み込み、台帳キーの一意性を保証する。

**`ResearchAgentTools`** は Layer 1 のツール層だ。`ResearchToolKit` が `web_search` / `fetch` の 2 ツールを LLM ツールとして組み立て、取得結果を `SourceRegistry` へ記帳する。`SerperSearchProvider`（Google SERP）・`BraveSearchProvider`・`FallbackSearchProvider`（複数プロバイダーのフォールバックチェーン）・`ResilientSearchProvider`（キャッシュ・レートリミット・サーキットブレーカー付きラッパー）を提供し、`WebSearchProvider` プロトコルで独自バックエンドへの差し替えも可能だ。

**`ResearchAgent`**（このモジュール）は Layer 2 のエージェント層だ。`ResearchAgentExecutor` が `AgentLoop` を駆動し、`ResearchCitationGate` が `SourceRegistry` への照合で回答を検証する。`ResearcherAgent` はツール構成に応じた system prompt・AgentCard・委譲説明を組み立てる。

## Topics

### 入門

- <doc:GettingStarted>

### エージェント組立

- ``ResearcherAgent``
- ``ResearchAgentExecutor``

### 出典検証

- ``ResearchCitationGate``
