// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-research-agent",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ResearchStore", targets: ["ResearchStore"]),
        .library(name: "ResearchAgentTools", targets: ["ResearchAgentTools"]),
        .library(name: "ResearchAgent", targets: ["ResearchAgent"]),
    ],
    dependencies: [
        // Tool プロトコル・JSONSchema・SystemPrompt（プロバイダー非依存の契約層）
        .package(url: "https://github.com/no-problem-dev/swift-llm-client.git", from: "3.5.1"),
        // AgentExecutor / AgentLoop / TaskUpdater（A2A ワーカーの実行環境）
        .package(url: "https://github.com/no-problem-dev/swift-agent-runtime.git", from: "0.8.0"),
        // HTTP トランスポート抽象（テスト時に差し替え可能）
        .package(url: "https://github.com/no-problem-dev/swift-http-transport.git", from: "1.1.0"),
        // HTML 本文抽出
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        // Layer 0: ソース台帳（UI / LLM / ネットワーク非依存）。
        // タスク中に観測した URL・タイトル・取得済み本文の SSOT。
        .target(
            name: "ResearchStore"
        ),
        // Layer 1: Web 調査ツール群（web_search / fetch）。
        // 取得結果を SourceRegistry へ記帳する（検証はしない — 素材の提供と記帳まで）。
        .target(
            name: "ResearchAgentTools",
            dependencies: [
                "ResearchStore",
                .product(name: "LLMClient", package: "swift-llm-client"),
                .product(name: "LLMTool", package: "swift-llm-client"),
                .product(name: "HTTPTransport", package: "swift-http-transport"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        // Layer 2: researcher エージェントの組立（system prompt / AgentCard / 出典検証ゲート付き executor）
        .target(
            name: "ResearchAgent",
            dependencies: [
                "ResearchStore",
                "ResearchAgentTools",
                .product(name: "AgentRuntime", package: "swift-agent-runtime"),
                .product(name: "LLMClient", package: "swift-llm-client"),
                .product(name: "LLMTool", package: "swift-llm-client"),
                .product(name: "LLMAgentStep", package: "swift-llm-client"),
            ]
        ),
        .testTarget(
            name: "ResearchStoreTests",
            dependencies: ["ResearchStore"]
        ),
        .testTarget(
            name: "ResearchAgentTests",
            dependencies: ["ResearchAgent", "ResearchAgentTools"]
        ),
    ]
)
