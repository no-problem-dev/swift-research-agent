# ``ResearchStore``

リサーチセッションで観測した全ソースを記帳・照会するステートレスな台帳層。

## Overview

`ResearchStore` はパッケージの最下位レイヤーだ。UI・LLM・ネットワークに依存せず、
タスク中に観測した URL・タイトル・取得済み本文の SSOT（Single Source of Truth）を提供する。

このモジュールだけをインポートすることで、ツール層（`ResearchAgentTools`）や
エージェント層（`ResearchAgent`）と分離して `SourceRegistry` を扱える。
テスト時にモックを差し込む場合や、SPM マルチモジュール構成で依存グラフを
最小化したい場合に有効だ。

### SourceRegistry の役割

`SourceRegistry` は Swift `actor` として実装されたセッションスコープの台帳だ。
`ResearchToolKit`（ツール側）と `ResearchAgentExecutor`（検証側）の両方に
同じインスタンスを渡すことで、ツールが記帳した観測ソースをゲートが照合できる。

```swift
import ResearchStore

// セッション開始時に 1 つ作成し、ツールとゲートへ共有注入する
let registry = SourceRegistry()

// ツールが検索結果を記帳（fetched=false: 引用にはまだ使えない）
await registry.registerSearchResult(
    url: "https://example.com/article",
    title: "記事タイトル",
    snippet: "要約テキスト",
    date: "2024-01-01",
    position: 1
)

// ツールが fetch 成功を記帳（fetched=true: 引用可になる）
await registry.registerFetch(
    url: "https://example.com/article",
    title: "記事タイトル（確定）",
    content: "ページの全文テキスト..."
)

// ゲートが引用照合で利用
let record = await registry.record(citing: "https://example.com/article")
print(record?.fetched)  // Optional(true)
```

### URLNormalization によるゆれの吸収

`URLNormalization.normalize(_:)` は URL の表記ゆれ（トラッキングパラメータ・
フラグメント・`www.` プレフィックス・末尾スラッシュ等）を畳み込んで
台帳キーの一意性を保証する。
`SourceRegistry` はすべての記帳・照会をこの正規化経由で行うため、
LLM が微妙に異なる表記で URL を引用しても偽陰性が起きない。

```swift
import ResearchStore

let key1 = URLNormalization.normalize("https://www.example.com/page/?utm_source=twitter#section")
let key2 = URLNormalization.normalize("https://example.com/page/")
// key1 == key2  → 同一キーに畳み込まれる
```

## Topics

### ソース台帳

- ``SourceRegistry``
- ``SourceRecord``

### URL 正規化

- ``URLNormalization``
