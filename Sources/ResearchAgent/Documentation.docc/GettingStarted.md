# Getting started

Assemble a research worker whose answers are checked against the pages it fetched, and understand what that check is worth.

## Installation

Add the package to `Package.swift`.

```swift
.package(url: "https://github.com/no-problem-dev/swift-research-agent.git", from: "0.1.1")
```

Then depend on the libraries your target needs.

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

## Building a checked research worker

### 1. Create the ledger

`SourceRegistry` is scoped to one task. Hand the **same instance** to the tool kit and to the
executor: the tools write to it, the gate reads from it, and with two different instances every
citation would look fabricated.

```swift
import ResearchStore
import ResearchAgentTools
import ResearchAgent

let registry = SourceRegistry()
```

### 2. Configure the tools

With Serper (Google's result page), the factory also wraps the provider in the default resilience
layers — one request per second, one retry, a breaker that opens after five failures, and a
five-minute result cache.

```swift
let toolKit = ResearchToolKit.serper(
    registry: registry,
    apiKey: "YOUR_SERPER_KEY",
    gl: "jp",
    hl: "ja"
)
```

With Brave Search, pass the provider directly. Brave results carry no date and no rank, so those two
fields stay `nil` in the ledger.

```swift
let toolKit = ResearchToolKit(
    registry: registry,
    searchProvider: BraveSearchProvider(apiKey: "YOUR_BRAVE_KEY", searchLang: "ja", country: "JP")
)
```

Passing no provider at all is a supported configuration: the kit then offers `fetch` only, and the
prompt and the delegation description follow suit if you pass `tools: [.fetch]` to them as well.

### 3. Assemble the executor

`ResearcherAgent.systemPrompt()` builds the prompt from the same tool set the worker will hold.
Its default output constraint asks for concise Japanese — override `outputConstraint` for any other
language.

```swift
import AgentRuntime   // InMemoryAgentHistory
import LLMClient      // PromptCachePolicy

let executor = ResearchAgentExecutor(
    client: anthropicClient,          // any client conforming to AgentCapableClient
    model: .claude_opus_4_5,
    tools: ToolSet { toolKit.tools(enabled: ResearchToolID.allTools) },
    systemPrompt: ResearcherAgent.systemPrompt(),
    maxSteps: 16,
    registry: registry,
    maxRetries: 2,                    // corrective retries after a failed citation check
    cachePolicy: .implicit,
    history: InMemoryAgentHistory()
)
```

### 4. Run a task

`ResearchAgentExecutor` conforms to `AgentExecutor`, so it registers with the runtime like any other
worker. The response artifact carries the cited sources as a `[SourceRecord]` JSON array under
`ResearchAgentExecutor.referencesMetadataKey` (`"research.references"`), and the token usage under
`"llm.usage"`.

```swift
let runtime = AgentRuntime(executor: executor, card: ResearcherAgent.card())
```

## How the check works

`ResearchCitationGate` uses no network and no LLM. It extracts every http(s) URL from the answer and
matches each one against the ledger:

- No URL at all in the answer — one violation, and nothing else is examined. Since only tool results
  can supply a URL, requiring a citation is what forces the model to use the tools.
- A URL with no record — it never came back from `web_search` or `fetch` in this task.
- A URL recorded but never fetched — a search snippet is a lead, not evidence.

Matching happens on the normalized key, so `www.`, tracking parameters, a fragment or a trailing
slash make no difference, while a different path or query is a different page and counts as uncited.
Violations are turned into a corrective message and the loop runs again.

### What it does not catch

- **The last attempt is unchecked.** After `maxRetries` corrections the answer is emitted as it
  stands, so an answer that never passes still reaches the caller. Setting `maxRetries: 0` disables
  the check altogether. If it matters to you whether an answer was checked, run
  `ResearchCitationGate.validate(text:registry:)` yourself on the artifact.
- **Provenance is not support.** Once a page has been fetched, it can be cited for anything — the
  gate never compares the answer against the stored page text.
- **A silent gap in the ledger looks like fabrication.** A URL that fails normalization is dropped
  from the ledger without an error even when the fetch succeeded, and citing it is then reported as
  a URL that never appeared in a tool result.
