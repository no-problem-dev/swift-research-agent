import Foundation
import LLMClient
import LLMTool

// MARK: - ToolKit Protocol

/// A named group of tools handed to an agent together.
///
/// Implement it to offer a set of related tools in-process, instead of running an external MCP
/// server to provide them.
///
/// ## Example
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
    /// Identifier for logs and debugging.
    ///
    /// The model never sees it, and it does not namespace the tool names: two kits that both
    /// provide a `fetch` tool collide.
    var name: String { get }

    /// Every tool this kit provides; adding the kit to a tool set adds all of them.
    var tools: [any Tool] { get }
}

// MARK: - ToolKit Default Extensions

extension ToolKit {
    public var toolCount: Int {
        tools.count
    }

    public var toolNames: [String] {
        tools.map { $0.toolName }
    }

    public func tool(named name: String) -> (any Tool)? {
        tools.first { $0.toolName == name }
    }
}

// MARK: - BuiltInTool

/// A tool defined by a closure rather than by a type of its own.
///
/// Holds the declaration the model sees — name, description, input schema, annotations — and runs
/// the closure when the model calls it.
public struct BuiltInTool: Tool, Sendable {
    // MARK: - Properties

    /// Name sent to the model in the tool declaration, and the name it calls back with.
    public let toolName: String
    /// Text the model reads when deciding whether to call this tool.
    public let toolDescription: String
    /// Schema the model generates its arguments against.
    public let inputSchema: JSONSchema
    /// Behaviour hints such as read-only or open-world; all unspecified by default.
    public let annotations: ToolAnnotations

    private let executeHandler: @Sendable (Data) async throws -> ToolResult

    // MARK: - Initialization

    /// Creates a tool from a handler closure.
    ///
    /// - Parameters:
    ///   - name: Name the model calls. Keep it stable; it appears in every declaration.
    ///   - description: Text the model uses to decide when to call this tool.
    ///   - inputSchema: Schema the model generates arguments against.
    ///   - annotations: Behaviour hints; all unspecified by default.
    ///   - handler: Runs on call, receiving the raw argument JSON.
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

    /// Runs the handler with the model's raw arguments.
    ///
    /// - Parameter argumentsData: Arguments as JSON, exactly as the model produced them; decoding
    ///   them is the handler's job.
    /// - Throws: Whatever the handler throws, unchanged.
    public func execute(with argumentsData: Data) async throws -> ToolResult {
        try await executeHandler(argumentsData)
    }

}
