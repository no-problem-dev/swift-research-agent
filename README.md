---
title: swift-research-agent README
created: 2026-06-27
tags: [swift, spm, agent, research, llm]
status: active
---

# swift-research-agent

> 出典検証ゲート付きの Web リサーチエージェント — 検索・取得・引用検証を 3 層構造で提供する Swift Package。

LLM エージェントが「記憶や検索スニペットだけに基づいた引用」を生成するのを構造的に防ぐ。
`web_search` と `fetch` ツールが観測したソースを `SourceRegistry` に記帳し、`ResearchCitationGate` が「fetch 済みページしか引用できない」規約を決定論的に検証する。
違反があれば是正メッセージを積んで自動再試行し、合格した回答に構造化出典データを添付する。

## アーキテクチャ概要

```
ResearchStore          Layer 0 — ソース台帳（UI / LLM / ネットワーク非依存）
    └── SourceRegistry     観測した URL・fetch 本文の SSOT（actor）

ResearchAgentTools     Layer 1 — Web 調査ツール群
    ├── ResearchToolKit    web_search / fetch ツールを提供、SourceRegistry に記帳
    ├── SerperSearchProvider   Google SERP (serper.dev)
    ├── BraveSearchProvider    Brave Search API
    ├── FallbackSearchProvider 複数プロバイダーの自動フォールバック
    └── ResilientSearchProvider レート制限 / サーキットブレーカー / LRU キャッシュ

ResearchAgent          Layer 2 — エージェント組立
    ├── ResearchAgentExecutor  AgentLoop + 出典検証リトライ + artifact 出力
    ├── ResearchCitationGate   fetch 済み確認・URL 実在確認の決定論的ゲート
    └── ResearcherAgent        system prompt / AgentCard の自己記述
```

## 提供モジュール

### `ResearchStore`

ネットワーク・LLM に依存しない純粋なデータ層。タスク中に観測した全ソースを管理する。

| 型 | 役割 |
|---|---|
| `SourceRegistry` | 観測ソースの台帳（`actor`）。`registerSearchResult` / `registerFetch` で記帳し、`record(citing:)` / `references(citedURLs:)` で照会する |
| `SourceRecord` | 1 ソースの記録（URL・タイトル・スニペット・fetch 済みフラグなど）|

### `ResearchAgentTools`

Web 調査ツールと検索プロバイダーを提供する。SourceRegistry への記帳まで担い、引用の検証はしない。

| 型 | 役割 |
|---|---|
| `ResearchToolKit` | `web_search` / `fetch` ツールを LLM に提供する `ToolKit`。`SourceRegistry` と共有して記帳する |
| `ResearchToolID` | ツール ID の列挙（`.webSearch` / `.fetch`）。有効化するツールセットを ToolKit・system prompt・AgentCard で一致させるための SSOT |
| `WebSearchProvider` | 検索バックエンドの抽象プロトコル |
| `SerperSearchProvider` | Serper API 経由の Google SERP 検索 |
| `BraveSearchProvider` | Brave Search API 検索 |
| `FallbackSearchProvider` | 複数プロバイダーの順番試行チェーン |
| `ResilientSearchProvider` | レート制限 + サーキットブレーカー + LRU キャッシュを統合したラッパー |
| `SearchResilienceConfiguration` | レジリエンス設定（RPS・失敗閾値・キャッシュ TTL など）|

### `ResearchAgent`

エージェントの組立と出典検証ロジック。

| 型 | 役割 |
|---|---|
| `ResearchAgentExecutor` | `AgentLoop` を回し、`ResearchCitationGate` で回答を検証。違反時は是正メッセージを積んで再試行（上限 `maxRetries`）。合格した回答に `research.references` メタデータを添付する |
| `ResearchCitationGate` | 「出典 URL が台帳に存在し fetch 済みか」を決定論的に検証。ネットワーク・LLM 不要 |
| `ResearcherAgent` | system prompt / AgentCard の自己記述。有効ツール構成に応じて内容を剪定する |

## インストール

### Swift Package Manager

`Package.swift` の `dependencies` に追加:

```swift
.package(url: "https://github.com/no-problem-dev/swift-research-agent.git", from: "1.0.0")
```

使用するターゲットに追加:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "ResearchAgent", package: "swift-research-agent"),
        .product(name: "ResearchAgentTools", package: "swift-research-agent"),
        .product(name: "ResearchStore", package: "swift-research-agent"),
    ]
)
```

## 使用例

### 基本: ResearchToolKit の組み立て

```swift
import ResearchStore
import ResearchAgentTools

// SourceRegistry はセッションスコープの actor — ToolKit とゲートで共有する
let registry = SourceRegistry()

// Serper プロバイダー付き（レジリエンスあり）
let toolKit = ResearchToolKit.serper(
    registry: registry,
    apiKey: "YOUR_SERPER_API_KEY",
    gl: "jp",
    hl: "ja"
)

// 利用可能なツール ID を確認
print(toolKit.availableToolIDs)  // [.webSearch, .fetch]
```

### 検索プロバイダーのフォールバックチェーン

```swift
import ResearchAgentTools

// Brave が失敗したら Serper にフォールバック
let provider = FallbackSearchProvider(providers: [
    BraveSearchProvider(apiKey: "BRAVE_KEY", searchLang: "ja", country: "JP"),
    SerperSearchProvider(apiKey: "SERPER_KEY", gl: "jp", hl: "ja"),
])

let toolKit = ResearchToolKit(registry: registry, searchProvider: provider)
```

### レジリエンス設定のカスタマイズ

```swift
import ResearchAgentTools

let resilience = SearchResilienceConfiguration(
    maxRequestsPerSecond: 2.0,   // レート制限: 2 req/sec
    failureThreshold: 3,          // 3 回失敗でサーキットブレーカー open
    resetTimeout: 30,             // 30 秒後に half-open
    cacheTTL: 600,                // 10 分キャッシュ
    maxCacheEntries: 200,
    maxRetries: 2
)

let toolKit = ResearchToolKit.serper(
    registry: registry,
    apiKey: "YOUR_API_KEY",
    resilience: resilience
)
```

### ResearchAgentExecutor の組み立て（swift-agent-runtime 連携）

```swift
import ResearchStore
import ResearchAgentTools
import ResearchAgent
import AgentRuntime
import LLMClient

let registry = SourceRegistry()
let toolKit = ResearchToolKit.serper(registry: registry, apiKey: "SERPER_KEY")

// ツール構成（有効化するツール ID を 1 箇所で決めて全層に反映）
let enabledTools: Set<ResearchToolID> = ResearchToolID.allTools

// ToolSet 構築
let toolSet = ToolSet { toolKit.tools(enabled: enabledTools) }

// executor 構築
let executor = ResearchAgentExecutor(
    client: myLLMClient,
    model: myModel,
    tools: toolSet,
    systemPrompt: ResearcherAgent.systemPrompt(
        outputConstraint: "Reply concisely in Japanese.",
        tools: enabledTools
    ),
    maxSteps: 16,
    registry: registry,
    maxRetries: 2,
    cachePolicy: .default,
    history: myHistoryStore
)
```

### ResearchCitationGate の単体検証

```swift
import ResearchStore
import ResearchAgent

let registry = SourceRegistry()

// ツールが fetch 成功を記帳した後
await registry.registerFetch(
    url: "https://example.com/article",
    title: "Example Article",
    content: "..."
)

// 回答テキストを検証
let issues = await ResearchCitationGate.validate(
    text: "詳細は https://example.com/article を参照。",
    registry: registry
)

if issues.isEmpty {
    print("出典検証 OK")
} else {
    // 是正メッセージを生成して LLM に再入力
    let corrective = ResearchCitationGate.corrective(issues: issues)
    print(corrective)
}
```

### Artifact から References を取り出す

```swift
import ResearchAgent
import ResearchStore

// ResearchAgentExecutor が合格した回答に添付するキー
let key = ResearchAgentExecutor<MyClient>.referencesMetadataKey  // "research.references"

if let json = artifact.metadata?[key],
   case .string(let jsonString) = json,
   let data = jsonString.data(using: .utf8),
   let references = try? JSONDecoder().decode([SourceRecord].self, from: data) {
    for ref in references {
        print("\(ref.title ?? ref.url)  fetched=\(ref.fetched)")
    }
}
```

## 出典検証の仕組み

`ResearchCitationGate` は 3 つの規約を順に検証する。

| 規約 | 内容 |
|---|---|
| 出典必須 | 回答に URL が 1 件以上引用されていること（ツールを使わない回答の排除） |
| 実在 | 引用 URL が `SourceRegistry` に記帳されていること（記憶・捏造 URL の排除）|
| 取得済み | 引用 URL が `fetch` 成功済みであること（スニペットのみを根拠にした引用の排除） |

URL は正規化（トラッキングパラメータ・フラグメント・www 畳み込み）して照合するため、表記ゆれによる偽陰性が起きない。
検証はネットワークも LLM も使わない決定論的処理。

## エラーハンドリング

```swift
import ResearchAgentTools

do {
    let results = try await provider.search(query: "Swift 6", maxResults: 5)
} catch WebSearchError.providerNotConfigured {
    // ResearchToolKit に searchProvider が注入されていない
} catch WebSearchError.circuitBreakerOpen {
    // 連続失敗によりサーキットブレーカーが open 状態
} catch WebSearchError.httpError(let statusCode) {
    // HTTP エラー（429: レート制限, 403: アクセス拒否 など）
}

do {
    // fetch ツールの内部エラー
} catch ResearchToolError.domainNotAllowed(let domain, let allowed) {
    // allowedDomains を設定した場合のドメイン制限違反
} catch ResearchToolError.contentTooLarge(let size, let maxSize) {
    // PDF・バイナリなど変換不可コンテンツ
}
```

## 対応プラットフォーム

| プラットフォーム | 最小バージョン |
|---|---|
| macOS | 14.0+ |
| iOS | 17.0+ |

Swift 6 / strict concurrency 対応（`SourceRegistry` / `RateLimiter` / `CircuitBreaker` / `SearchResultCache` はすべて `actor`）。

## 関連パッケージ

| パッケージ | 役割 |
|---|---|
| [swift-llm-client](https://github.com/no-problem-dev/swift-llm-client) | `Tool` / `ToolSet` / `SystemPrompt` / `AgentCapableClient` の定義 |
| [swift-agent-runtime](https://github.com/no-problem-dev/swift-agent-runtime) | `AgentExecutor` / `AgentLoop` / `TaskUpdater` の実行環境 |
| [swift-http-transport](https://github.com/no-problem-dev/swift-http-transport) | HTTP トランスポート抽象（テスト時にモック差し替え可） |

---

最終更新: 2026-06-27
