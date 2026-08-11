# swift-research-agent

English | [日本語](./README.ja.md)

Stop a research agent citing pages it never opened — its answer is checked against a ledger of what it actually fetched, and sent back when it does not hold up.

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017+%20%7C%20macOS%2014+-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## Overview

An agent that searches the web will happily produce a citation from a search snippet, or from
memory, or from nothing at all. This package gives it `web_search` and `fetch` tools that record
every source they touch in a ledger, and then checks the finished answer against that ledger before
anyone sees it.

An answer that cites nothing at all is rejected outright — only a tool result can supply a URL, so
requiring one indirectly requires the agent to go and look. Beyond that, each cited URL has to be
present in the ledger and to have been fetched successfully; a search result the agent only glanced
at is not enough. Matching is on a normalised key, so `www.`, tracking parameters, fragments and
trailing slashes all fold together, while a different path or query is a different page. The check
runs on recorded state alone: no network call, no second model, same verdict every time.

When the answer fails, the agent is told which citations were bad and asked to try again, up to a
retry limit you set. When it passes, the sources travel with the answer as structured metadata, so
the surface showing it can list references without re-deriving them.

Every attempt is checked, the last one included, so `maxRetries: 0` means one attempt that is still
checked. An answer that never passes is never completed: once the retry budget is spent the task
fails, carrying the violations and the rejected text, so nothing downstream can mistake it for a
verified answer.

**One limit, before you call this hallucination-proof.** Only provenance is checked, never support —
a page that was fetched can be cited for a claim it never made, or contradicts. What it does rule
out is a citation to a URL this task never fetched: one recalled from training, one invented, or one
seen in a snippet and never opened.

- **Search backends are swappable** — Serper and Brave included, or chain several so one outage does
  not end the task
- **Bad days degrade instead of failing** — request rate limiting, a circuit breaker that stops
  hammering a failing provider, and a bounded result cache
- **The tool set is decided once** — the same configuration drives the tools, the system prompt and
  the agent's self-description, so they cannot drift apart
- **Fetching can be fenced** — restrict to an allow-list of domains and cap response size

## Quick Start

```swift
import ResearchStore
import ResearchAgentTools

// One session-scoped ledger, shared by the tools and the gate
let registry = SourceRegistry()

let toolKit = ResearchToolKit.serper(
    registry: registry,
    apiKey: "YOUR_SERPER_API_KEY",
    gl: "jp",
    hl: "ja"
)

print(toolKit.availableToolIDs)  // [.webSearch, .fetch]
```

Check an answer yourself, without running a whole agent:

```swift
import ResearchAgent

await registry.registerFetch(url: "https://example.com/article", title: "Example", content: "...")

let issues = await ResearchCitationGate.validate(
    text: "See https://example.com/article for details.",
    registry: registry
)
if !issues.isEmpty {
    let corrective = ResearchCitationGate.corrective(issues: issues)  // feed back to the model
}
```

## Documentation

[**ResearchAgent**](https://no-problem-dev.github.io/swift-research-agent/documentation/researchagent/) —
assembling the agent, the citation gate and the retry loop, including
[Getting Started](https://no-problem-dev.github.io/swift-research-agent/documentation/researchagent/gettingstarted/).

[**ResearchAgentTools**](https://no-problem-dev.github.io/swift-research-agent/documentation/researchagenttools/) —
the tools, the search providers, and what happens when one fails.

[**ResearchStore**](https://no-problem-dev.github.io/swift-research-agent/documentation/researchstore/) —
the source ledger the gate reads.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-research-agent.git", .upToNextMinor(from: "0.1.0"))
]
```

```swift
.product(name: "ResearchAgent",      package: "swift-research-agent"),
.product(name: "ResearchAgentTools", package: "swift-research-agent"),
.product(name: "ResearchStore",      package: "swift-research-agent"),
```

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 6.2+

## License

MIT — see [LICENSE](LICENSE).
