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

### 兄弟モジュールとの役割分担

このパッケージは 3 層構造で成り立っています。

**`ResearchStore`** はパッケージ最下位の台帳層です。`SourceRegistry` actor がタスク中に観測した全 URL の記録（`SourceRecord`）を保持します。UI・LLM・ネットワークに依存せず、単独でインポートして使えます。検索結果（`fetched == false`）と fetch 成功（`fetched == true`）を区別して記帳し、引用可否の判定根拠を提供します。また `URLNormalization` がトラッキングパラメータ・フラグメント・`www.` 等の表記ゆれを畳み込み、台帳キーの一意性を保証します。

**`ResearchAgentTools`** は Layer 1 のツール層です。`ResearchToolKit` が `web_search` / `fetch` の 2 ツールを LLM ツールとして組み立て、取得結果を `SourceRegistry` へ記帳します。`SerperSearchProvider`（Google SERP）・`BraveSearchProvider`・`FallbackSearchProvider`（複数プロバイダーのフォールバックチェーン）・`ResilientSearchProvider`（キャッシュ・レートリミット・サーキットブレーカー付きラッパー）を提供し、`WebSearchProvider` プロトコルで独自バックエンドへの差し替えも可能です。

**`ResearchAgent`**（このモジュール）は Layer 2 のエージェント層です。`ResearchAgentExecutor` が `AgentLoop` を駆動し、`ResearchCitationGate` が `SourceRegistry` への照合で回答を検証します。`ResearcherAgent` はツール構成に応じた system prompt・AgentCard・委譲説明を組み立てます。

## Topics

### Essentials

- <doc:GettingStarted>

### エージェント組立

- ``ResearcherAgent``
- ``ResearchAgentExecutor``

### 出典検証

- ``ResearchCitationGate``
