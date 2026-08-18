import MCP
import XCTest
@testable import ossuno_mcp

final class MCPToolSchemaTests: XCTestCase, @unchecked Sendable {
    func testListObjectsExposesContinuationToken() throws {
        let tool = try XCTUnwrap(
            MCPServerCommand.toolDefinitions().first { $0.name == "list_objects" }
        )
        let properties = try schemaProperties(tool.inputSchema)
        guard case .object(let tokenSchema) = properties["continuation_token"],
              case .string(let type) = tokenSchema["type"] else {
            return XCTFail("continuation_token schema missing")
        }
        XCTAssertEqual(type, "string")
    }

    func testUploadExposesExplicitOverwriteAndDestructiveHint() throws {
        let tool = try XCTUnwrap(
            MCPServerCommand.toolDefinitions().first { $0.name == "upload_file" }
        )
        let properties = try schemaProperties(tool.inputSchema)
        guard case .object(let overwriteSchema) = properties["overwrite"],
              case .string(let type) = overwriteSchema["type"],
              case .bool(let defaultValue) = overwriteSchema["default"] else {
            return XCTFail("overwrite schema missing")
        }
        XCTAssertEqual(type, "boolean")
        XCTAssertFalse(defaultValue)
        guard case .string(let overwriteDescription) = overwriteSchema["description"] else {
            return XCTFail("overwrite description missing")
        }
        XCTAssertTrue(overwriteDescription.contains("跳过版本状态与存在性保护"))
        XCTAssertTrue(overwriteDescription.contains("可能不可逆"))
        XCTAssertEqual(tool.annotations.destructiveHint, true)
        XCTAssertEqual(tool.annotations.idempotentHint, false)
        let description = try XCTUnwrap(tool.description)
        XCTAssertTrue(description.contains("Suspended"))
        XCTAssertTrue(description.contains("Enabled"))
        XCTAssertTrue(description.contains("状态无法确认"))
    }

    private func schemaProperties(_ schema: Value) throws -> [String: Value] {
        guard case .object(let root) = schema,
              case .object(let properties) = root["properties"] else {
            throw SchemaError.invalid
        }
        return properties
    }

    private enum SchemaError: Error {
        case invalid
    }
}
