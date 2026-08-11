# ``ResearchAgentTools``

The `web_search` and `fetch` tools, the search backends behind them, and the bookkeeping that makes citations checkable.

## Overview

`ResearchAgentTools` is the middle layer of the package. It builds the two tools an LLM calls during
research and records what they observe in a `SourceRegistry`: search hits as
not-yet-fetched, successful fetches as citable with the page text stored.

That is where its responsibility stops. Deciding whether an answer's citations are acceptable
belongs to the gate in `ResearchAgent`; this module only supplies the material and the record.

### ResearchToolKit

``ResearchToolKit`` takes the ledger and a search provider, and offers the tools. For Serper
(Google's result page) there is a factory that also wraps the provider in the resilience layers.

```swift
import ResearchStore
import ResearchAgentTools

let registry = SourceRegistry()

// Serper, with the default cache, rate limit, breaker and retry
let toolKit = ResearchToolKit.serper(
    registry: registry,
    apiKey: "YOUR_SERPER_KEY",
    gl: "jp",
    hl: "ja"
)
```

Brave Search, or any backend of your own, goes to the initializer directly.

```swift
let toolKit = ResearchToolKit(
    registry: registry,
    searchProvider: BraveSearchProvider(apiKey: "YOUR_BRAVE_KEY", searchLang: "ja", country: "JP")
)
```

### What the tools do

`fetch` downloads a URL with a browser user agent, extracts the readable content as Markdown, stores
the **whole** extracted text in the ledger, and returns a slice of it. Long pages are read by calling
it again with `start_index`; every slice comes from the same stored text, so one fetch is enough to
make the page citable. Failures throw — a non-2xx status, a blocked domain, an unsupported scheme, an
oversized binary body — and each error message tells the model what to try instead. Nothing is
retried at this layer, and a URL that could not be fetched is not in the ledger, so it cannot be
cited.

`web_search` runs the query, returns titles, URLs and snippets, and records each hit as
not-yet-fetched. Its tool description says outright that snippets are leads rather than facts,
because the gate will reject a citation backed only by one.

### Selective enabling

``ResearchToolID`` names the tools so that the kit, the system prompt and the delegation description
can be built from one set and cannot drift apart.

```swift
// fetch only — no search provider needed
let fetchOnlyTools = toolKit.tools(enabled: [.fetch])

// every tool (the default)
let allTools = toolKit.tools(enabled: ResearchToolID.allTools)
```

`fetch` is a core tool and survives `enabled: []`: it is the only path that can mark a URL as
fetched, so without it no source could ever be citable. `web_search` is dropped whenever it is not
enabled **or** no provider is configured — ask ``ResearchToolKit/availableToolIDs`` to tell "switched
off" from "cannot be switched on".

### Search providers

Implement ``WebSearchProvider`` to plug in a backend the package does not ship. Two wrappers compose
on top of any provider, including your own.

```swift
let brave = BraveSearchProvider(apiKey: "BRAVE_KEY")
let serper = SerperSearchProvider(apiKey: "SERPER_KEY")

// Try providers in order; an empty result set counts as a failure and moves on
let fallback = FallbackSearchProvider(providers: [brave, serper])

// Cache, rate limit, circuit breaker and retries
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

``ResilientSearchProvider`` consults its cache before the breaker, so repeated queries keep answering
while the breaker is open. Every failed attempt, retries included, counts toward opening it.
``BraveSearchProvider`` reports neither a date nor a rank, so sources found through it reach the
ledger without those two signals.

## Topics

### Tool kit

- ``ResearchToolKit``
- ``ResearchToolID``
- ``ToolKit``
- ``BuiltInTool``

### Search providers

- ``WebSearchProvider``
- ``WebSearchResult``
- ``SerperSearchProvider``
- ``BraveSearchProvider``
- ``FallbackSearchProvider``
- ``ResilientSearchProvider``
- ``UnconfiguredSearchProvider``

### Resilience

- ``SearchResilienceConfiguration``
- ``RateLimiter``
- ``CircuitBreaker``
- ``SearchResultCache``

### Content extraction

- ``WebContentExtractor``
- ``ExtractedContent``
- ``SwiftSoupContentExtractor``

### Errors

- ``ResearchToolError``
- ``WebSearchError``
