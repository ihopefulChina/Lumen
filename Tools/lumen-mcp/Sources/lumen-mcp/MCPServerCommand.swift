import Foundation
import MCP

enum MCPServerCommand {
    static func run() async -> Int32 {
        let server = Server(
            name: "lumen-mcp",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.toolDefinitions())
        }

        await server.withMethodHandler(CallTool.self) { params in
            await Self.handleCall(params)
        }

        let transport = StdioTransport()
        do {
            try await server.start(transport: transport)
            // start() is non-blocking; wait until the message loop ends (stdin EOF).
            await server.waitUntilCompleted()
        } catch {
            // Transport failure — still a normal shutdown path for stdio servers.
        }
        return 0
    }

    // MARK: - Tool definitions

    private static func toolDefinitions() -> [Tool] {
        func schema(_ properties: [String: Value], required: [String]) -> Value {
            .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ])
        }
        func stringProp(_ describe: String) -> Value {
            .object(["type": .string("string"), "description": .string(describe)])
        }
        func intProp(_ describe: String, _ default: Int) -> Value {
            .object([
                "type": .string("integer"),
                "description": .string(describe),
                "default": .int(`default`),
            ])
        }

        return [
            Tool(
                name: "list_buckets",
                description: "列出当前 OSS 账号下的所有 Bucket（名称、地域、创建时间）。",
                inputSchema: schema([:], required: []),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "list_objects",
                description: "列出指定 Bucket 中的对象和子文件夹。默认按文件夹层级（delimiter=/）浏览；要递归列出所有对象时传 delimiter 为空字符串。",
                inputSchema: schema([
                    "bucket": stringProp("Bucket 名称"),
                    "prefix": stringProp("对象前缀（文件夹路径），可选"),
                    "delimiter": stringProp("分隔符，默认 '/'；空字符串表示递归列出"),
                    "max_keys": intProp("最多返回条数（1-1000），默认 200", 200),
                ], required: ["bucket"]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "upload_file",
                description: "上传本机文件到 OSS。适合图片、文档等任意文件；大文件建议使用 Lumen App 获得分片续传。返回对象 URL。",
                inputSchema: schema([
                    "bucket": stringProp("目标 Bucket 名称"),
                    "local_path": stringProp("本地文件的绝对路径"),
                    "key": stringProp("目标对象 Key（含路径），缺省使用本地文件名"),
                    "content_type": stringProp("Content-Type，缺省按扩展名推断"),
                ], required: ["bucket", "local_path"]),
                annotations: .init(idempotentHint: true)
            ),
            Tool(
                name: "download_file",
                description: "从 OSS 下载对象到本机指定路径。",
                inputSchema: schema([
                    "bucket": stringProp("Bucket 名称"),
                    "key": stringProp("对象 Key"),
                    "local_path": stringProp("本地保存的绝对路径"),
                ], required: ["bucket", "key", "local_path"])
            ),
            Tool(
                name: "presign_url",
                description: "为私有 Bucket 中的对象生成带签名的临时下载链接。",
                inputSchema: schema([
                    "bucket": stringProp("Bucket 名称"),
                    "key": stringProp("对象 Key"),
                    "expires_seconds": intProp("链接有效期（秒），默认 3600，最长 604800", 3600),
                ], required: ["bucket", "key"]),
                annotations: .init(readOnlyHint: true)
            ),
        ]
    }

    // MARK: - Dispatch

    private static func handleCall(_ params: CallTool.Parameters) async -> CallTool.Result {
        let arguments = params.arguments ?? [:]
        let client: MCPOSSClient
        do {
            let profile = try ProfileStore.loadActive()
            client = MCPOSSClient(profile: profile)
        } catch {
            return errorResult(
                "\(error.localizedDescription)\n请先运行 `lumen-mcp auth` 配置 OSS 凭证。"
            )
        }

        do {
            switch params.name {
            case "list_buckets":
                return try await listBuckets(client)
            case "list_objects":
                return try await listObjects(client, arguments)
            case "upload_file":
                return try await uploadFile(client, arguments)
            case "download_file":
                return try await downloadFile(client, arguments)
            case "presign_url":
                return try await presignURL(client, arguments)
            default:
                return errorResult("未知工具：\(params.name)")
            }
        } catch {
            return errorResult("操作失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Tool implementations

    private static func listBuckets(_ client: MCPOSSClient) async throws -> CallTool.Result {
        let buckets = try await client.listBuckets()
        let formatter = ISO8601DateFormatter()
        let payload = buckets.map { bucket -> [String: Value] in
            var item: [String: Value] = [
                "name": .string(bucket.name),
                "region": .string(bucket.regionID),
            ]
            if let createdAt = bucket.createdAt {
                item["created_at"] = .string(formatter.string(from: createdAt))
            }
            return item
        }
        return textResult(Self.encodeJSON([
            "count": .int(buckets.count),
            "buckets": .array(payload.map { .object($0) }),
        ]))
    }

    private static func listObjects(_ client: MCPOSSClient, _ arguments: [String: Value]) async throws -> CallTool.Result {
        guard let bucket = arguments["bucket"]?.mcpString, !bucket.isEmpty else {
            throw MissingArgumentError("bucket")
        }
        let prefix = arguments["prefix"]?.mcpString
        let delimiterRaw = arguments["delimiter"]?.mcpString
        let delimiter: String?
        if let delimiterRaw {
            delimiter = delimiterRaw.isEmpty ? nil : delimiterRaw
        } else {
            delimiter = "/"
        }
        let maxKeys = arguments["max_keys"]?.mcpInt ?? 200

        let listing = try await client.listObjects(
            bucket: bucket,
            prefix: prefix,
            delimiter: delimiter,
            maxKeys: maxKeys
        )
        let formatter = ISO8601DateFormatter()
        let folders = listing.folders.map { folder -> [String: Value] in
            ["prefix": .string(folder.prefix)]
        }
        let objects = listing.objects.map { object -> [String: Value] in
            var item: [String: Value] = [
                "key": .string(object.key),
                "size": .int(Int(object.size)),
            ]
            if let lastModified = object.lastModified {
                item["last_modified"] = .string(formatter.string(from: lastModified))
            }
            if !object.etag.isEmpty {
                item["etag"] = .string(object.etag)
            }
            return item
        }
        var payload: [String: Value] = [
            "bucket": .string(bucket),
            "prefix": .string(prefix ?? ""),
            "folders": .array(folders.map { .object($0) }),
            "objects": .array(objects.map { .object($0) }),
            "truncated": .bool(listing.isTruncated),
        ]
        if let next = listing.nextToken {
            payload["next_continuation_token"] = .string(next)
        }
        return textResult(Self.encodeJSON(.object(payload)))
    }

    private static func uploadFile(_ client: MCPOSSClient, _ arguments: [String: Value]) async throws -> CallTool.Result {
        guard let bucket = arguments["bucket"]?.mcpString, !bucket.isEmpty else {
            throw MissingArgumentError("bucket")
        }
        guard let localPath = arguments["local_path"]?.mcpString, !localPath.isEmpty else {
            throw MissingArgumentError("local_path")
        }
        let fileURL = URL(fileURLWithPath: NSString(string: localPath).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw MissingArgumentError("local_path（文件不存在或不是普通文件：\(fileURL.path)）")
        }
        var key = arguments["key"]?.mcpString ?? ""
        if key.isEmpty {
            key = fileURL.lastPathComponent
        }
        key = key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let contentType = arguments["content_type"]?.mcpString
            ?? contentTypeHint(forExtension: fileURL.pathExtension)

        let result = try await client.uploadFile(
            bucket: bucket,
            key: key,
            fileURL: fileURL,
            contentType: contentType
        )
        return textResult(Self.encodeJSON([
            "bucket": .string(result.bucket),
            "key": .string(result.key),
            "size": .int(Int(result.size)),
            "etag": .string(result.etag),
            "url": .string(result.url.absoluteString),
            "note": .string("url 为直链；若 Bucket 为私有读，请改用 presign_url 工具生成临时链接。"),
        ]))
    }

    private static func downloadFile(_ client: MCPOSSClient, _ arguments: [String: Value]) async throws -> CallTool.Result {
        guard let bucket = arguments["bucket"]?.mcpString, !bucket.isEmpty else {
            throw MissingArgumentError("bucket")
        }
        guard let key = arguments["key"]?.mcpString, !key.isEmpty else {
            throw MissingArgumentError("key")
        }
        guard let localPath = arguments["local_path"]?.mcpString, !localPath.isEmpty else {
            throw MissingArgumentError("local_path")
        }
        let destination = URL(fileURLWithPath: NSString(string: localPath).expandingTildeInPath)
        let result = try await client.downloadFile(bucket: bucket, key: key, to: destination)
        return textResult(Self.encodeJSON([
            "bucket": .string(result.bucket),
            "key": .string(result.key),
            "local_path": .string(result.localPath),
            "size": .int(Int(result.size)),
        ]))
    }

    private static func presignURL(_ client: MCPOSSClient, _ arguments: [String: Value]) async throws -> CallTool.Result {
        guard let bucket = arguments["bucket"]?.mcpString, !bucket.isEmpty else {
            throw MissingArgumentError("bucket")
        }
        guard let key = arguments["key"]?.mcpString, !key.isEmpty else {
            throw MissingArgumentError("key")
        }
        var expires = arguments["expires_seconds"]?.mcpInt ?? 3600
        expires = max(1, min(expires, 604_800))
        let url = try client.presignedURL(bucket: bucket, key: key, expires: expires)
        return textResult(Self.encodeJSON([
            "url": .string(url.absoluteString),
            "expires_seconds": .int(expires),
        ]))
    }

    // MARK: - Helpers

    private static func textResult(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    private static func encodeJSON(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func contentTypeHint(forExtension ext: String) -> String? {
        let table = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "webp": "image/webp",
            "avif": "image/avif",
            "svg": "image/svg+xml",
            "heic": "image/heic",
            "pdf": "application/pdf",
            "json": "application/json",
            "txt": "text/plain",
            "md": "text/markdown",
            "html": "text/html",
            "css": "text/css",
            "js": "text/javascript",
            "mp4": "video/mp4",
            "mp3": "audio/mpeg",
            "zip": "application/zip",
        ]
        return table[ext.lowercased()]
    }
}

struct MissingArgumentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { "缺少或无效的参数：\(message)" }
}

extension Value {
    var mcpString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var mcpInt: Int? {
        if case .int(let value) = self { return value }
        if case .double(let value) = self { return Int(value) }
        return nil
    }
}
