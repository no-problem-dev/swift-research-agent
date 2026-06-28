---
title: swift-research-agent README
created: 2026-06-27
tags: [swift, spm, agent, research, llm]
status: active
---

# swift-research-agent

English | [日本語](./README.ja.md)

> Web research agent with citation-verification gate — a Swift Package providing search, fetch, and citation validation in a 3-layer architecture.

Structurally prevents LLM agents from generating citations based only on memory or search snippets.
`web_search` and `fetch` tools register observed sources into `SourceRegistry`, and
`ResearchCitationGate` deterministically verifies that "only fetched pages may be cited."
Violations trigger automatic retries with corrective messages; passing answers include structured citation data as artifact metadata.

## Architecture

```
ResearchStore          Layer 0 — Source ledger (UI / LLM / network-independent)
    └── SourceRegistry     SSOT for observed URLs and fetched content (actor)

ResearchAgentTools     Layer 1 — Web research tools
    ├── ResearchToolKit    Provides web_search / fetch tools; registers to SourceRegistry
    ├── SerperSearchProvider   Google SERP (serper.dev)
    ├── BraveSearchProvider    Brave Search API
    ├── FallbackSearchProvider Auto-fallback chain across multiple providers
    └── ResilientSearchProvider Rate limiting / circuit breaker / LRU cache

ResearchAgent          Layer 2 — Agent assembly
    ├── ResearchAgentExecutor  AgentLoop + citation validation retry + artifact output
    ├── ResearchCitationGate   Deterministic gate: checks fetch status and URL existence
    └── ResearcherAgent        system prompt / AgentCard self-description
```

## Modules

### `ResearchStore`

Pure data layer with no dependency on network, LLM, or UI. Manages all sources observed during a task.

| Type | Role |
|---|---|
| `SourceRegistry` | Source ledger (`actor`). Register via `registerSearchResult` / `registerFetch`; query via `record(citing:)` / `references(citedURLs:)` |
| `SourceRecord` | Record for a single source (URL, title, snippet, fetch status, etc.) |

### `ResearchAgentTools`

Provides web research tools and search providers. Handles registration to `SourceRegistry`; does not validate citations.

| Type | Role |
|---|---|
| `ResearchToolKit` | `ToolKit` that exposes `web_search` / `fetch` tools to the LLM; registers observations to `SourceRegistry` |
| `ResearchToolID` | Tool ID enum (`.webSearch` / `.fetch`). Single source of truth for the enabled tool set used by ToolKit, system prompt, and AgentCard |
| `WebSearchProvider` | Abstract protocol for search backends |
| `SerperSearchProvider` | Google SERP search via Serper API |
| `BraveSearchProvider` | Brave Search API |
| `FallbackSearchProvider` | Sequential fallback chain across multiple providers |
| `ResilientSearchProvider` | Wrapper integrating rate limiting + circuit breaker + LRU cache |
| `SearchResilienceConfiguration` | Resilience settings (RPS, failure threshold, cache TTL, etc.) |

### `ResearchAgent`

Agent assembly and citation-validation logic.

| Type | Role |
|---|---|
| `ResearchAgentExecutor` | Drives `AgentLoop`, validates answers with `ResearchCitationGate`, retries on violations (up to `maxRetries`), attaches `research.references` metadata to passing answers |
| `ResearchCitationGate` | Deterministically verifies that cited URLs exist in the ledger and are fetched. No network or LLM required |
| `ResearcherAgent` | Builds system prompt / AgentCard / delegation description from the active tool configuration |

## Installation

### Swift Package Manager

Add to `Package.swift` dependencies:

```swift
.package(url: "https://github.com/no-problem-dev/swift-research-agent.git", from: "0.1.1")
```

Add to your target:

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

## Usage

### Basic: Building a ResearchToolKit

```swift
import ResearchStore
import ResearchAgentTools

// SourceRegistry is a session-scoped actor — share it between the ToolKit and the gate
let registry = SourceRegistry()

// Serper provider with default resilience
let toolKit = ResearchToolKit.serper(
    registry: registry,
    apiKey: "YOUR_SERPER_API_KEY",
    gl: "jp",
    hl: "ja"
)

// Inspect available tool IDs
print(toolKit.availableToolIDs)  // [.webSearch, .fetch]
```

### Fallback Chain for Search Providers

```swift
import ResearchAgentTools

// Fall back to Serper if Brave fails
let provider = FallbackSearchProvider(providers: [
    BraveSearchProvider(apiKey: "BRAVE_KEY", searchLang: "ja", country: "JP"),
    SerperSearchProvider(apiKey: "SERPER_KEY", gl: "jp", hl: "ja"),
])

let toolKit = ResearchToolKit(registry: registry, searchProvider: provider)
```

### Custom Resilience Configuration

```swift
import ResearchAgentTools

let resilience = SearchResilienceConfiguration(
    maxRequestsPerSecond: 2.0,   // rate limit: 2 req/sec
    failureThreshold: 3,          // open circuit breaker after 3 failures
    resetTimeout: 30,             // half-open after 30 seconds
    cacheTTL: 600,                // 10-minute cache
    maxCacheEntries: 200,
    maxRetries: 2
)

let toolKit = ResearchToolKit.serper(
    registry: registry,
    apiKey: "YOUR_API_KEY",
    resilience: resilience
)
```

### Assembling ResearchAgentExecutor (with swift-agent-runtime)

```swift
import ResearchStore
import ResearchAgentTools
import ResearchAgent
import AgentRuntime
import LLMClient

let registry = SourceRegistry()
let toolKit = ResearchToolKit.serper(registry: registry, apiKey: "SERPER_KEY")

// Decide the enabled tool set once; propagate to all layers
let enabledTools: Set<ResearchToolID> = ResearchToolID.allTools

// Build the ToolSet
let toolSet = ToolSet { toolKit.tools(enabled: enabledTools) }

// Build the executor
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
    cachePolicy: .implicit,
    history: myHistoryStore
)
```

### Standalone Citation Gate Validation

```swift
import ResearchStore
import ResearchAgent

let registry = SourceRegistry()

// After a tool registers a successful fetch
await registry.registerFetch(
    url: "https://example.com/article",
    title: "Example Article",
    content: "..."
)

// Validate the answer text
let issues = await ResearchCitationGate.validate(
    text: "See https://example.com/article for details.",
    registry: registry
)

if issues.isEmpty {
    print("Citation validation passed")
} else {
    // Generate a corrective message and feed it back to the LLM
    let corrective = ResearchCitationGate.corrective(issues: issues)
    print(corrective)
}
```

### Extracting References from an Artifact

```swift
import ResearchAgent
import ResearchStore

// The key ResearchAgentExecutor attaches to passing answers
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

## How Citation Verification Works

`ResearchCitationGate` validates three rules in order:

| Rule | Description |
|---|---|
| Citation required | The answer must cite at least one URL (eliminates answers that bypass tools) |
| Existence | The cited URL must appear in `SourceRegistry` (eliminates hallucinated URLs) |
| Fetched | The cited URL must have been successfully fetched (eliminates snippet-only citations) |

URLs are normalized (tracking parameters, fragments, `www.` folding) before matching, preventing false negatives from minor variations. Verification is fully deterministic — no network or LLM calls.

## Error Handling

```swift
import ResearchAgentTools

do {
    let results = try await provider.search(query: "Swift 6", maxResults: 5)
} catch WebSearchError.providerNotConfigured {
    // No WebSearchProvider injected into ResearchToolKit
} catch WebSearchError.circuitBreakerOpen {
    // Circuit breaker opened due to repeated failures
} catch WebSearchError.httpError(let statusCode) {
    // HTTP error (429: rate limited, 403: access denied, etc.)
}

do {
    // fetch tool internal errors
} catch ResearchToolError.domainNotAllowed(let domain, let allowed) {
    // Domain blocked when allowedDomains is set
} catch ResearchToolError.contentTooLarge(let size, let maxSize) {
    // Binary content (PDF, image, etc.) that cannot be converted to text
}
```

## Supported Platforms

| Platform | Minimum Version |
|---|---|
| macOS | 14.0+ |
| iOS | 17.0+ |

Swift 6 / strict concurrency compliant (`SourceRegistry`, `RateLimiter`, `CircuitBreaker`, `SearchResultCache` are all `actor`).

## Related Packages

| Package | Role |
|---|---|
| [swift-llm-client](https://github.com/no-problem-dev/swift-llm-client) | Defines `Tool` / `ToolSet` / `SystemPrompt` / `AgentCapableClient` |
| [swift-agent-runtime](https://github.com/no-problem-dev/swift-agent-runtime) | Provides `AgentExecutor` / `AgentLoop` / `TaskUpdater` runtime |
| [swift-http-transport](https://github.com/no-problem-dev/swift-http-transport) | HTTP transport abstraction (swappable mock for testing) |

---

Last updated: 2026-06-29
