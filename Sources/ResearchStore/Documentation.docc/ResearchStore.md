# ``ResearchStore``

The ledger a research task writes its sources into, and the URL canonicalization that decides when two citations mean the same page.

## Overview

`ResearchStore` is the bottom layer of the package. It depends on nothing — no UI, no LLM, no
network — and holds the single record of what a task observed: which URLs were seen, which of them
were actually fetched, and the text of the pages that were.

Import it on its own when you want the ledger without the tool layer (`ResearchAgentTools`) or the
agent layer (`ResearchAgent`): to write a fake ledger in tests, or to keep a dependency graph small.

### SourceRegistry

``SourceRegistry`` is an actor scoped to one task. Give the same instance to the tool kit and to the
executor, or the gate has nothing to match citations against.

```swift
import ResearchStore

// One per task, injected into both the tools and the gate
let registry = SourceRegistry()

// A tool records a search hit (fetched = false: not citable yet)
await registry.registerSearchResult(
    url: "https://example.com/article",
    title: "Article title",
    snippet: "Summary text",
    date: "2024-01-01",
    position: 1
)

// A tool records a successful fetch (fetched = true: citable)
await registry.registerFetch(
    url: "https://example.com/article",
    title: "Article title, as the page states it",
    content: "The whole page text..."
)

// The gate looks a citation up
let record = await registry.record(citing: "https://example.com/article")
print(record?.fetched)  // Optional(true)
```

Two properties of the ledger are worth knowing before you rely on it:

- **A URL that fails to normalize is still recorded, under its own spelling.** Registration returns
  the ``SourceKey`` it used, so a caller can tell a `.canonical` key from a `.verbatim` one: a
  verbatim key still makes the page citable, but spelling variants of it no longer fold together.
- **Nothing is persisted and nothing is evicted.** The ledger lives as long as the actor. Stored
  page text is capped per source (200,000 characters by default), but the number of sources is not,
  so a long-running task grows monotonically.

### URLNormalization

``URLNormalization/normalize(_:)`` folds the spellings that do not change which page is meant —
tracking parameters, fragment, `www.`, default port, scheme and host case, query order, trailing
slash — into one ledger key. Every registration and lookup goes through it, so a model that cites a
URL slightly differently from the one it fetched still matches.

```swift
import ResearchStore

let key1 = URLNormalization.normalize("https://www.example.com/page/?utm_source=twitter#section")
let key2 = URLNormalization.normalize("https://example.com/page/")
// key1 == key2
```

Rewrites that could change the page are deliberately not done: path case is preserved, and nothing
is redirected or resolved over the network. A different path or query is a different key, and
therefore a different source.

## Topics

### The ledger

- ``SourceRegistry``
- ``SourceRecord``

### URL identity

- ``URLNormalization``
