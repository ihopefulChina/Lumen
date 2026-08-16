import Foundation

/// `lumen-mcp install` / `lumen-mcp uninstall` — one-command registration
/// into local MCP clients (Claude Desktop, Claude Code, Cursor, Trae,
/// Windsurf, Codex). JSON configs are merged in place (never clobbered,
/// a .bak copy is kept); Codex uses TOML section upsert.
enum InstallCommand {
    struct Client: Sendable {
        let id: String
        let displayName: String
        /// Config file (nil for CLI-managed clients like Claude Code).
        let configURL: URL?
        /// "json" (mcpServers merge) or "toml" ([mcp_servers.lumen] upsert).
        let format: String
        /// How to detect that this client is installed on this machine.
        let detect: @Sendable () -> Bool
    }

    static let serverKey = "lumen"

    static var clients: [Client] {
        // LUMEN_MCP_HOME lets tests/sandboxes redirect every config path;
        // normal users never set it and getpwuid home is used.
        let home: URL
        if let override = ProcessInfo.processInfo.environment["LUMEN_MCP_HOME"], !override.isEmpty {
            home = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        func exists(_ path: String) -> Bool {
            @Sendable func fileExists(_ path: String) -> Bool {
                FileManager.default.fileExists(atPath: path)
            }
            return fileExists(path)
        }
        return [
            Client(
                id: "claude-desktop",
                displayName: "Claude Desktop",
                configURL: appSupport.appendingPathComponent("Claude/claude_desktop_config.json"),
                format: "json",
                detect: { exists(appSupport.appendingPathComponent("Claude").path) }
            ),
            Client(
                id: "cursor",
                displayName: "Cursor",
                configURL: home.appendingPathComponent(".cursor/mcp.json"),
                format: "json",
                detect: { exists(home.appendingPathComponent(".cursor").path) }
            ),
            Client(
                id: "trae",
                displayName: "Trae",
                configURL: appSupport.appendingPathComponent("Trae/User/settings/mcp.json"),
                format: "json",
                detect: { exists(appSupport.appendingPathComponent("Trae").path) }
            ),
            Client(
                id: "windsurf",
                displayName: "Windsurf",
                configURL: home.appendingPathComponent(".windsurf/mcp.json"),
                format: "json",
                detect: { exists(home.appendingPathComponent(".windsurf").path) }
            ),
            Client(
                id: "codex",
                displayName: "Codex",
                configURL: home.appendingPathComponent(".codex/config.toml"),
                format: "toml",
                detect: { exists(home.appendingPathComponent(".codex").path) }
            ),
        ]
    }

    // MARK: - Entry point

    static func run(arguments: [String], uninstalling: Bool) async -> Int32 {
        var requested: [String] = []
        var dryRun = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--client":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    fail("用法：lumen-mcp \(uninstalling ? "uninstall" : "install") --client <\(clientIDs())>")
                    return 64
                }
                requested.append(arguments[index])
            case "--all":
                requested = clients.map(\.id)
            case "--dry-run":
                dryRun = true
            case "--help", "-h":
                printHelp(uninstalling: uninstalling)
                return 0
            default:
                fail("未知参数：\(arguments[index])")
                printHelp(uninstalling: uninstalling)
                return 64
            }
            index += 1
        }

        for id in requested where clients.first(where: { $0.id == id }) == nil {
            fail("未知客户端「\(id)」。可选：\(clientIDs())")
            return 64
        }

        // Auto-detect when nothing requested. Claude Code is CLI-managed and
        // always attempted when its CLI is on PATH.
        let targets: [Client]
        if requested.isEmpty {
            targets = clients.filter { $0.detect() }
        } else {
            targets = clients.filter { requested.contains($0.id) }
        }

        let binaryPath: String
        if uninstalling {
            binaryPath = "" // not needed for removal
        } else {
            guard let resolved = currentBinaryPath() else {
                fail("无法定位 lumen-mcp 可执行文件（argv0=\(CommandLine.arguments.first ?? "")）。请用绝对路径运行。")
                return 1
            }
            binaryPath = resolved
        }

        guard !targets.isEmpty || !requested.isEmpty || isClaudeCodeInstalled() else {
            print("未检测到已安装的 MCP 客户端（Claude Desktop / Cursor / Trae / Windsurf / Codex）。")
            print("可运行 `lumen-mcp install --client <id>` 强制写入指定客户端的配置文件。")
            return 0
        }

        var failures = 0

        // Claude Code via its own CLI (keeps ~/.claude.json internals consistent).
        let wantClaudeCode = requested.isEmpty ? isClaudeCodeInstalled() : requested.contains("claude-code")
        if wantClaudeCode {
            if isClaudeCodeInstalled() {
                let ok = uninstalling
                    ? runCLIClaudeCode(["mcp", "remove", serverKey, "-s", "user"])
                    : runCLIClaudeCode(["mcp", "add", "--scope", "user", serverKey, "--", binaryPath])
                if ok {
                    print("✓ Claude Code 已\(uninstalling ? "移除" : "注册")（scope: user）")
                } else {
                    failures += 1
                }
            } else if !requested.isEmpty {
                fail("未找到 claude 命令，无法配置 Claude Code。")
                failures += 1
            }
        }

        for client in targets {
            guard let url = client.configURL else { continue }
            do {
                if dryRun {
                    let preview = try buildNewContent(for: client, url: url, binaryPath: binaryPath, uninstalling: uninstalling)
                    print("[dry-run] \(client.displayName) → \(url.path)")
                    print(preview.isEmpty ? "（文件不存在，将新建）" : preview)
                    continue
                }
                try apply(client, url: url, binaryPath: binaryPath, uninstalling: uninstalling)
                print("✓ \(client.displayName) 已\(uninstalling ? "移除" : "注册")：\(url.path)")
            } catch {
                fail("\(client.displayName) \(uninstalling ? "移除" : "注册")失败：\(error.localizedDescription)")
                failures += 1
            }
        }

        if !dryRun && failures == 0 {
            if !uninstalling {
                printNextSteps(binaryPath: binaryPath)
            } else {
                print("完成。如有客户端正在运行，重启后生效。")
            }
        }
        return failures == 0 ? 0 : 1
    }

    private static func clientIDs() -> String {
        (clients.map(\.id) + ["claude-code"]).joined(separator: "|")
    }

    private static func printHelp(uninstalling: Bool) {
        print("""
        lumen-mcp \(uninstalling ? "uninstall" : "install") — 把 lumen-mcp \(uninstalling ? "从" : "注册到")本机 MCP 客户端

        用法：
          lumen-mcp \(uninstalling ? "uninstall" : "install")                    自动检测已安装的客户端并\(uninstalling ? "移除" : "注册")
          lumen-mcp \(uninstalling ? "uninstall" : "install") --client cursor   只处理指定客户端（可重复传）
          lumen-mcp \(uninstalling ? "uninstall" : "install") --all             处理全部支持的客户端
          lumen-mcp \(uninstalling ? "uninstall" : "install") --dry-run         只预览将要写入的内容

        支持的客户端：claude-desktop、claude-code、cursor、trae、windsurf、codex
        JSON 配置采用合并写入并保留 .bak 备份，不影响其他 MCP 服务器。
        """)
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    // MARK: - Binary path resolution

    private static func currentBinaryPath() -> String? {
        let argv0 = CommandLine.arguments.first ?? ""
        var url: URL
        if argv0.hasPrefix("/") {
            url = URL(fileURLWithPath: argv0)
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            url = URL(fileURLWithPath: cwd).appendingPathComponent(argv0)
        }
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: resolved.path) else {
            return nil
        }
        return resolved.path
    }

    private static func isClaudeCodeInstalled() -> Bool {
        runProcess("/usr/bin/env", ["which", "claude"], printOutput: false)?.0 == 0
    }

    /// Returns true on success. Prints claude CLI output on failure for diagnosis.
    private static func runCLIClaudeCode(_ arguments: [String]) -> Bool {
        guard let (code, output) = runProcess("/usr/bin/env", ["claude"] + arguments, printOutput: false) else {
            fail("无法启动 claude 命令。")
            return false
        }
        if code != 0, !output.isEmpty {
            fail("claude CLI 输出：\(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return code == 0
    }

    @discardableResult
    private static func runProcess(_ executable: String, _ arguments: [String], printOutput: Bool) -> (Int32, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if printOutput { print(output) }
        return (process.terminationStatus, output)
    }

    // MARK: - Config writing

    private static func apply(_ client: Client, url: URL, binaryPath: String, uninstalling: Bool) throws {
        let newContent = try buildNewContent(for: client, url: url, binaryPath: binaryPath, uninstalling: uninstalling)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep a .bak copy of the previous version before touching the file.
        // Write via Data (atomic replace) instead of remove+copy so an
        // existing .bak never breaks the run.
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            try? existing.write(to: URL(fileURLWithPath: url.path + ".bak"), options: .atomic)
        }
        try newContent.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func buildNewContent(for client: Client, url: URL, binaryPath: String, uninstalling: Bool) throws -> String {
        switch client.format {
        case "json":
            return try mergeJSON(url: url, binaryPath: binaryPath, uninstalling: uninstalling)
        case "toml":
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return upsertTOMLSection(existing, section: "mcp_servers.\(serverKey)", body: ["command = \(tomlString(binaryPath))"], removing: uninstalling)
        default:
            throw InstallError.unsupportedFormat(client.format)
        }
    }

    private static func mergeJSON(url: URL, binaryPath: String, uninstalling: Bool) throws -> String {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.invalidJSON(url.path)
            }
            root = existing
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if uninstalling {
            servers.removeValue(forKey: serverKey)
        } else {
            servers[serverKey] = ["command": binaryPath]
        }
        if servers.isEmpty {
            root.removeValue(forKey: "mcpServers")
        } else {
            root["mcpServers"] = servers
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw InstallError.invalidJSON(url.path)
        }
        return text + "\n"
    }

    /// Line-based upsert/removal of a `[section]` block in a TOML file.
    /// The section spans from its header to the next top-level `[` header or EOF.
    private static func upsertTOMLSection(_ source: String, section: String, body: [String], removing: Bool) -> String {
        var lines = source.components(separatedBy: "\n")
        let header = "[\(section)]"
        var index = 0
        var replaced = false
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == header {
                var end = index + 1
                while end < lines.count {
                    let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { break }
                    end += 1
                }
                let replacement = removing ? [] : ([header] + body)
                lines.replaceSubrange(index..<end, with: replacement)
                replaced = true
                break
            }
            index += 1
        }
        if !replaced && !removing {
            // Append at end of file; ensure exactly one blank line separation.
            while lines.last == "" { lines.removeLast() }
            lines.append("")
            lines.append(header)
            lines.append(contentsOf: body)
        }
        // Normalize: strip trailing blank lines, single trailing newline.
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func printNextSteps(binaryPath: String) {
        print("""
        下一步：
        1. 重启对应的 AI 客户端使配置生效。
        2. 首次调用时 macOS 可能弹钥匙串授权窗，点「始终允许」。
        3. 若尚未配置 OSS 凭证，运行：lumen-mcp auth
        """)
        _ = binaryPath
    }
}

enum InstallError: LocalizedError {
    case invalidJSON(String)
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let path):
            return "配置文件不是合法 JSON：\(path)（已保留 .bak 备份，可手动修复后重试）"
        case .unsupportedFormat(let format):
            return "不支持的配置格式：\(format)"
        }
    }
}
