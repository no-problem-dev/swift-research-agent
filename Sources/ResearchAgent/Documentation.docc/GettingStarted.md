# Getting Started with ResearchAgent

出典検証ゲート付きリサーチエージェントを組み立て、検索→フェッチ→引用検証のループを実行する。

## Installation

`Package.swift` に依存を追加します。

```swift
.package(url: "https://github.com/no-problem-dev/swift-research-agent.git", from: "0.1.1")
```

使用するターゲットに必要なライブラリを指定します。

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "ResearchAgent", package: "swift-research-agent"),
        .product(name: "ResearchAgentTools", package: "swift-research-agent"),
        .product(name: "ResearchStore", package: "swift-research-agent"),
    ]
)
```

## Basic Usage: 出典検証付きリサーチの組み立て

### 1. SourceRegistry を作成する

`SourceRegistry` はセッションスコープの台帳です。`ResearchToolKit`（ツール側）と `ResearchAgentExecutor`（検証側）の両方に同じインスタンスを渡すことで、ツールが記帳したソースをゲートが照合できます。

```swift
import ResearchStore
import ResearchAgentTools
import ResearchAgent

let registry = SourceRegistry()
```

### 2. ResearchToolKit を構成する

Serper（Google SERP）を使う場合は `ResearchToolKit.serper` ファクトリを使います。`gl`/`hl` で地域・言語を指定できます。

```swift
let toolKit = ResearchToolKit.serper(
    registry: registry,
    apiKey: "YOUR_SERPER_KEY",
    gl: "jp",
    hl: "ja"
)
```

Brave Search を使う場合は `BraveSearchProvider` を直接渡します。

```swift
let toolKit = ResearchToolKit(
    registry: registry,
    searchProvider: BraveSearchProvider(apiKey: "YOUR_BRAVE_KEY", searchLang: "ja", country: "JP")
)
```

### 3. ResearchAgentExecutor を組み立てる

`ResearcherAgent.systemPrompt()` は有効ツール構成に合わせてプロンプトを生成します。`web_search` を無効にする場合は `tools: [.fetch]` を渡します。

```swift
import AgentRuntime // AgentCapableClient, InMemoryAgentHistory

let executor = ResearchAgentExecutor(
    client: anthropicClient,          // AgentCapableClient を実装したクライアント
    model: .claude_opus_4_5,
    tools: ToolSet { toolKit },
    systemPrompt: ResearcherAgent.systemPrompt(),
    maxSteps: 16,
    registry: registry,
    maxRetries: 2,                    // 出典検証 NG 時の是正リトライ上限
    cachePolicy: .none,
    history: InMemoryAgentHistory()
)
```

### 4. タスクを実行する

`AgentExecutor` として `AgentRuntime` に登録し、タスクリクエストを送信します。合格した回答のアーティファクトには `ResearchAgentExecutor.referencesMetadataKey`（`"research.references"`）キーで引用出典の `[SourceRecord]` JSON が付きます。

```swift
// ResearchAgentExecutor は AgentExecutor を実装しているため、
// AgentRuntime が提供する実行基盤にそのまま登録できます。
let runtime = AgentRuntime(executor: executor, card: ResearcherAgent.card())
```

### 出典検証の仕組み

`ResearchCitationGate` はネットワークも LLM も使わず、`SourceRegistry` との照合だけで検証します。

- 引用 URL が台帳に存在しない → 捏造 URL として違反
- 引用 URL が `fetched == false`（検索スニペットのみ）→ フェッチ未実施として違反
- 違反がある場合は是正メッセージを会話に積んで再ループ（`maxRetries` 回まで）

この設計により、LLM は必ず `web_search → fetch` の順でソースを確認してから引用するよう誘導されます。
