# ``ResearchAgent``

A web research worker whose citations are checked against a ledger of the pages it actually fetched, and re-prompted when they do not hold up.

## Overview

`ResearchAgent` is the top layer of `swift-research-agent`. It contributes three things:

- **Self-description** — ``ResearcherAgent`` builds the system prompt, the agent card and the
  delegation blurb from one enabled-tool set, so the prompt never mentions a tool the worker lacks.
- **Execution** — ``ResearchAgentExecutor`` drives the agent loop, checks the answer, and re-prompts
  with the violations until they clear or the retry budget runs out.
- **The check itself** — ``ResearchCitationGate`` matches the answer's URLs against the ledger,
  with no network and no LLM involved.

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

### What the gate does and does not guarantee

Every http(s) URL in an answer must resolve, after normalization, to a ledger record that was
fetched. A URL with no record, or one that only ever appeared in search results, is a violation, and
violations become a corrective turn for the model.

Every attempt is checked, the last one included, so `maxRetries: 0` means one attempt that is still
checked. An answer that never satisfies the gate is never completed: once the retries are spent the
task fails, carrying the violations and the rejected text.

One limit matters before you describe this as preventing hallucinated citations:

- **Only provenance is checked, never support.** A page that was fetched can be cited for any claim,
  including one it contradicts. The ledger stores the page text, but the gate never compares it
  against the answer.

What it does rule out is a citation to a URL this task did not fetch: a URL from the model's memory,
a plausible-looking URL it invented, or a URL it saw in a search snippet and never opened.

A completed task carries one text artifact plus metadata: token usage under `llm.usage`, and the
cited sources as a `[SourceRecord]` JSON array under `research.references`.

### The three layers

**`ResearchStore`** is the ledger, dependency-free. `SourceRegistry` records every
observed URL and whether it was fetched; `URLNormalization` decides when two spellings mean the same
page. Importable on its own.

**`ResearchAgentTools`** is the tool layer. `ResearchToolKit` builds `web_search` and `fetch` and
records what they observe. `SerperSearchProvider`, `BraveSearchProvider`, `FallbackSearchProvider`
and `ResilientSearchProvider` cover the search backends, and `WebSearchProvider` lets you supply
your own.

**`ResearchAgent`** — this module — runs the loop and applies the check.

## Topics

### Getting started

- <doc:GettingStarted>

### Building the worker

- ``ResearcherAgent``
- ``ResearchAgentExecutor``

### Checking citations

- ``ResearchCitationGate``
