# swift-research-agent

[English](./README.md) | 日本語

開いてもいないページをリサーチエージェントに引用させない — 回答は「実際に fetch したもの」の台帳と突き合わされ、通らなければ差し戻される。

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017+%20%7C%20macOS%2014+-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## 概要

Web を検索するエージェントは、検索スニペットから、記憶から、あるいは何も無いところから、平気で出典を
でっち上げる。このパッケージは `web_search` と `fetch` ツールを与え、触ったソースを全て台帳に記帳させ、
書き上がった回答を人目に触れる前にその台帳と突き合わせる。

出典が 1 つも無い回答はその時点で却下する — URL を供給できるのはツール結果だけなので、1 つ要求することが
そのまま「実際に見に行くこと」の要求になる。その上で、引用された URL は台帳に存在し、かつ fetch に
成功していなければならない。検索結果を眺めただけでは足りない。突き合わせは正規化したキーで行うので、
`www.`・トラッキングパラメータ・フラグメント・末尾スラッシュは同一に畳まれ、パスやクエリが違えば別ページと
して扱われる。判定は記帳済みの状態だけで完結する — ネットワーク呼び出しも、2 つ目のモデルも要らず、
同じ文章はいつも同じ結果になる。

不合格なら、どの引用が駄目だったかをエージェントに伝えて再試行させる（回数は指定可能）。合格すれば、
出典が構造化メタデータとして回答に同行するので、表示側は参考文献をもう一度導出しなくてよい。

**「幻覚を防ぐ」と言う前に、限界が 2 つ。** 最後の 1 回はそのまま出る — 再試行の回数を使い切ったら、
まだ不合格でも回答は返る。`maxRetries: 0` なら検査は一度も走らない。そして検証するのは出どころだけで、
裏づけではない。fetch 済みのページは、そこに書かれていない主張、矛盾する主張にでも付けられる。
排除できるのは「このタスクで fetch していない URL の引用」— 学習データから思い出した URL、でっち上げた
URL、スニペットで見ただけで開いていない URL である。

- **検索バックエンドは差し替えられる** — Serper と Brave を同梱。複数を連鎖させれば 1 つ落ちても
  タスクは終わらない
- **調子の悪い日は落ちずに劣化する** — リクエストのレート制限、失敗し続ける提供元を叩くのをやめる
  サーキットブレーカー、上限付きの結果キャッシュ
- **ツール構成は一度だけ決める** — 同じ設定がツール・システムプロンプト・エージェントの自己紹介を
  駆動するので、三者がずれようがない
- **取得先は囲える** — 許可ドメインを限定し、レスポンスサイズに上限をかけられる

## クイックスタート

```swift
import ResearchStore
import ResearchAgentTools

// セッション単位の台帳を 1 つ。ツールとゲートで共有する
let registry = SourceRegistry()

let toolKit = ResearchToolKit.serper(
    registry: registry,
    apiKey: "YOUR_SERPER_API_KEY",
    gl: "jp",
    hl: "ja"
)

print(toolKit.availableToolIDs)  // [.webSearch, .fetch]
```

エージェントを丸ごと動かさずに、回答だけを検証する:

```swift
import ResearchAgent

await registry.registerFetch(url: "https://example.com/article", title: "Example", content: "...")

let issues = await ResearchCitationGate.validate(
    text: "See https://example.com/article for details.",
    registry: registry
)
if !issues.isEmpty {
    let corrective = ResearchCitationGate.corrective(issues: issues)  // モデルに差し戻す
}
```

## ドキュメント

[**ResearchAgent**](https://no-problem-dev.github.io/swift-research-agent/documentation/researchagent/) —
エージェントの組み立て、引用ゲート、再試行ループ。
[Getting Started](https://no-problem-dev.github.io/swift-research-agent/documentation/researchagent/gettingstarted/) を含む。

[**ResearchAgentTools**](https://no-problem-dev.github.io/swift-research-agent/documentation/researchagenttools/) —
ツール、検索プロバイダ、失敗したときに何が起きるか。

[**ResearchStore**](https://no-problem-dev.github.io/swift-research-agent/documentation/researchstore/) —
ゲートが読む出典台帳。

## インストール

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

## 要件

- iOS 17.0+ / macOS 14.0+
- Swift 6.2+

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
