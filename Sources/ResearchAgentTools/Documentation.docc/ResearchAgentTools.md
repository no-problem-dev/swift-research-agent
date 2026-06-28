# ``ResearchAgentTools``

`web_search` / `fetch` の 2 ツールと複数の検索プロバイダーを提供するツール層。観測した URL と取得済み本文を `SourceRegistry` へ記帳する。

## Overview

`ResearchAgentTools` はパッケージの Layer 1 です。Web 調査ツール群（`web_search` / `fetch`）を LLM ツールとして組み立て、取得結果を `SourceRegistry`（`ResearchStore` モジュール）へ記帳するまでを担います。引用の検証はゲート側（`ResearchAgent` モジュール）が行い、このモジュールは素材の提供と記帳に責務を限定します。

### ResearchToolKit の使い方

`ResearchToolKit` は `SourceRegistry` と検索プロバイダーを受け取って `web_search` / `fetch` ツールを提供します。Serper（Google SERP）を使う場合は便利なファクトリメソッドを使います。

```swift
import ResearchStore
import ResearchAgentTools

let registry = SourceRegistry()

// Serper ファクトリ（レジリエンスデフォルト付き）
let toolKit = ResearchToolKit.serper(
    registry: registry,
    apiKey: "YOUR_SERPER_KEY",
    gl: "jp",
    hl: "ja"
)
```

Brave Search や独自プロバイダーを使う場合はイニシャライザに直接渡します。

```swift
let toolKit = ResearchToolKit(
    registry: registry,
    searchProvider: BraveSearchProvider(apiKey: "YOUR_BRAVE_KEY", searchLang: "ja", country: "JP")
)
```

### ツール ID による選択的有効化

`ResearchToolID` でツールの有効・無効を制御できます。
`fetch` は `isCore == true` のため常に含まれます（無効化不可）。
`web_search` はプロバイダー未設定の場合 `enabled` に指定しても提供されません。

```swift
// fetch のみ（search プロバイダー不要の構成）
let fetchOnlyTools = toolKit.tools(enabled: [.fetch])

// 全ツール（デフォルト）
let allTools = toolKit.tools(enabled: ResearchToolID.allTools)
```

### 検索プロバイダーの階層

`WebSearchProvider` プロトコルを実装することで独自バックエンドを差し込めます。
`ResilientSearchProvider` でラップすることで、キャッシュ・レートリミット・
サーキットブレーカー・リトライを一括で付与できます。

```swift
let brave = BraveSearchProvider(apiKey: "BRAVE_KEY")
let serper = SerperSearchProvider(apiKey: "SERPER_KEY")

// 複数プロバイダーを優先順でフォールバック
let fallback = FallbackSearchProvider(providers: [brave, serper])

// レジリエンス機能を付与してラップ
let resilient = ResilientSearchProvider(
    provider: fallback,
    configuration: SearchResilienceConfiguration(
        maxRequestsPerSecond: 2.0,
        failureThreshold: 3,
        resetTimeout: 30,
        cacheTTL: 600,
        maxCacheEntries: 200,
        maxRetries: 2
    )
)

let toolKit = ResearchToolKit(registry: registry, searchProvider: resilient)
```

## Topics

### ToolKit

- ``ResearchToolKit``
- ``ResearchToolID``
- ``ToolKit``
- ``BuiltInTool``

### 検索プロバイダー

- ``WebSearchProvider``
- ``WebSearchResult``
- ``SerperSearchProvider``
- ``BraveSearchProvider``
- ``FallbackSearchProvider``
- ``ResilientSearchProvider``
- ``UnconfiguredSearchProvider``

### レジリエンス

- ``SearchResilienceConfiguration``
- ``RateLimiter``
- ``CircuitBreaker``
- ``SearchResultCache``

### コンテンツ抽出

- ``WebContentExtractor``
- ``ExtractedContent``
- ``SwiftSoupContentExtractor``

### エラー

- ``ResearchToolError``
- ``WebSearchError``
