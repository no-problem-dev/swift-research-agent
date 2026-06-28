import Foundation
import LLMClient
import LLMTool

// MARK: - ToolKit Protocol

/// 関連するツールをグループ化するプロトコル。
///
/// ToolKit は複数の関連ツールを束ねて提供する。
/// 外部 MCP サーバーと同等の機能を Swift 内で直接実装する際に使う。
///
/// ## 実装例
///
/// ```swift
/// public struct MyToolKit: ToolKit {
///     public var name: String { "my-toolkit" }
///
///     public var tools: [any Tool] {
///         [MyTool1(), MyTool2()]
///     }
/// }
/// ```
public protocol ToolKit: Sendable {
    /// ToolKit の識別名。
    ///
    /// ログやデバッグ時の識別に使う。
    var name: String { get }

    /// この ToolKit が提供するツールの配列。
    ///
    /// ToolSet に追加される際、この配列のすべてのツールが含まれる。
    var tools: [any Tool] { get }
}

// MARK: - ToolKit Default Extensions

extension ToolKit {
    /// ツール数
    public var toolCount: Int {
        tools.count
    }

    /// ツール名のリスト
    public var toolNames: [String] {
        tools.map { $0.toolName }
    }

    /// 名前でツールを検索
    ///
    /// - Parameter name: ツール名
    /// - Returns: 見つかったツール、またはnil
    public func tool(named name: String) -> (any Tool)? {
        tools.first { $0.toolName == name }
    }
}

// MARK: - BuiltInTool

/// ToolKit 内で使う個別ツールの実装型。
///
/// name・description・inputSchema・annotations を保持し、クロージャで execute を実装する。
public struct BuiltInTool: Tool, Sendable {
    // MARK: - Properties

    /// ツール識別名。LLM へ渡す `name` フィールドに使われる。
    public let toolName: String
    /// ツールの説明。LLM がツール選択時に参照する。
    public let toolDescription: String
    /// 入力引数の JSON スキーマ。LLM が引数を生成する際の型定義。
    public let inputSchema: JSONSchema
    /// ツールのメタ情報（冪等性・副作用など）。`ToolAnnotations()` で全デフォルト。
    public let annotations: ToolAnnotations

    private let executeHandler: @Sendable (Data) async throws -> ToolResult

    // MARK: - Initialization

    /// BuiltInTool を作成する。
    ///
    /// - Parameters:
    ///   - name: ツール名
    ///   - description: ツールの説明
    ///   - inputSchema: 入力スキーマ
    ///   - annotations: ツールアノテーション
    ///   - handler: 実行ハンドラー
    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        annotations: ToolAnnotations = ToolAnnotations(),
        handler: @escaping @Sendable (Data) async throws -> ToolResult
    ) {
        self.toolName = name
        self.toolDescription = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.executeHandler = handler
    }

    // MARK: - Tool Protocol

    /// ツールを実行する。
    ///
    /// - Parameter argumentsData: LLM から渡された引数の JSON データ。
    /// - Returns: ツールの実行結果。
    /// - Throws: ハンドラーが投げるエラーをそのまま伝播する。
    public func execute(with argumentsData: Data) async throws -> ToolResult {
        try await executeHandler(argumentsData)
    }

}
