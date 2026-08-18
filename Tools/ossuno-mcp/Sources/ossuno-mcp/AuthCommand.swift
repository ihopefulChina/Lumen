import Foundation

enum AuthCommand {
    static func run(arguments: [String]) async -> Int32 {
        let sub = arguments.first ?? ""
        switch sub {
        case "", "--interactive", "add":
            return await interactiveAdd()
        case "--list", "list":
            return list()
        case "--remove":
            guard arguments.count >= 2 else {
                FileHandle.standardError.write("用法：ossuno-mcp auth --remove <profile>\n".data(using: .utf8)!)
                return 64
            }
            return remove(name: arguments[1])
        case "--use":
            guard arguments.count >= 2 else {
                FileHandle.standardError.write("用法：ossuno-mcp auth --use <profile>\n".data(using: .utf8)!)
                return 64
            }
            return use(name: arguments[1])
        case "--test":
            return await test()
        case "--help", "-h", "help":
            printHelp()
            return 0
        default:
            FileHandle.standardError.write("未知的 auth 子命令：\(sub)\n".data(using: .utf8)!)
            printHelp()
            return 64
        }
    }

    static func printHelp() {
        print("""
        ossuno-mcp auth — 管理 OSS 凭证（独立于 Ossuno App 的钥匙串）

        用法：
          ossuno-mcp auth                 交互式添加/更新配置档案
          ossuno-mcp auth --list          列出所有配置档案
          ossuno-mcp auth --remove <名称>  删除配置档案
          ossuno-mcp auth --use <名称>     切换活动配置档案
          ossuno-mcp auth --test          验证当前凭证（调用 ListBuckets）
        """)
    }

    // MARK: - Subcommands

    private static func interactiveAdd() async -> Int32 {
        print("配置 Ossuno MCP 的 OSS 凭证（存储在当前用户的钥匙串中）")
        print("提示：建议使用最小权限的 RAM 子账号 AccessKey。\n")

        let existing = ProfileStore.listNames()
        if !existing.isEmpty {
            print("已有配置档案：\(existing.joined(separator: "、"))")
        }

        let name = prompt("配置名称 [\(ProfileStore.defaultProfileName)]") ?? ""
        let profileName = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? ProfileStore.defaultProfileName
            : name.trimmingCharacters(in: .whitespaces)

        let region = (prompt("地域 ID（如 cn-hangzhou）[cn-hangzhou]") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let regionID = region.isEmpty ? "cn-hangzhou" : region

        guard let ak = prompt("AccessKey ID"), !ak.trimmingCharacters(in: .whitespaces).isEmpty else {
            FileHandle.standardError.write("AccessKey ID 不能为空\n".data(using: .utf8)!)
            return 1
        }
        guard let sk = promptSecret("AccessKey Secret"), !sk.isEmpty else {
            FileHandle.standardError.write("AccessKey Secret 不能为空\n".data(using: .utf8)!)
            return 1
        }
        let token = promptSecret("STS Security Token（可选，普通 AK 直接回车）") ?? ""
        let endpoint = (prompt("自定义 Endpoint（可选，直接回车使用阿里云官方）") ?? "")
            .trimmingCharacters(in: .whitespaces)

        let profile = MCPOSSProfile(
            name: profileName,
            region: regionID,
            accessKeyId: ak.trimmingCharacters(in: .whitespaces),
            accessKeySecret: sk,
            securityToken: token.isEmpty ? nil : token,
            endpoint: endpoint.isEmpty ? nil : endpoint
        )
        do {
            try ProfileStore.save(profile)
            try ProfileStore.setActiveName(profileName)
        } catch {
            FileHandle.standardError.write("保存失败：\(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
        print("已保存配置档案「\(profileName)」并设为活动档案。")
        return 0
    }

    private static func list() -> Int32 {
        let names = ProfileStore.listNames()
        guard !names.isEmpty else {
            print("还没有配置档案。运行 ossuno-mcp auth 添加。")
            return 0
        }
        let active = ProfileStore.activeName()
        for name in names {
            var line = name == active ? "● " : "  "
            line += name
            if let profile = try? ProfileStore.load(name: name) {
                line += "  region=\(profile.region)  key=\(profile.accessKeyId.prefix(6))…"
            }
            print(line)
        }
        return 0
    }

    private static func remove(name: String) -> Int32 {
        do {
            try ProfileStore.delete(name: name)
            print("已删除配置档案「\(name)」。")
            return 0
        } catch {
            FileHandle.standardError.write("删除失败：\(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }

    private static func use(name: String) -> Int32 {
        guard ProfileStore.listNames().contains(name) else {
            FileHandle.standardError.write("找不到配置档案「\(name)」。运行 ossuno-mcp auth --list 查看。\n".data(using: .utf8)!)
            return 1
        }
        do {
            try ProfileStore.setActiveName(name)
            print("已切换到配置档案「\(name)」。")
            return 0
        } catch {
            FileHandle.standardError.write("切换失败：\(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }

    private static func test() async -> Int32 {
        let profile: MCPOSSProfile
        do {
            profile = try ProfileStore.loadActive()
        } catch {
            FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
        print("正在验证「\(profile.name)」（region=\(profile.region)）…")
        do {
            let count = try await MCPOSSClient(profile: profile).verifyCredentials()
            print("凭证有效，可见 \(count) 个 Bucket。")
            return 0
        } catch {
            FileHandle.standardError.write("验证失败：\(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }

    // MARK: - Input helpers

    private static func prompt(_ message: String) -> String? {
        print("\(message)：", terminator: "")
        fflush(stdout)
        guard let line = readLine() else { return nil }
        return line
    }

    private static func promptSecret(_ message: String) -> String? {
        print("\(message)：", terminator: "")
        fflush(stdout)
        // Disable terminal echo while reading, so the secret stays off-screen.
        // Falls back to plain reading when stdin is not a TTY (piped input).
        var original = termios()
        let isTTY = tcgetattr(STDIN_FILENO, &original) == 0
        if isTTY {
            var noEcho = original
            noEcho.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &noEcho)
        }
        // Collect raw bytes (NOT CChar — values > 127 would trap on Int8 init).
        var bytes: [UInt8] = []
        while true {
            let ch = getchar()
            if ch == EOF || ch == 0x0A { break }
            if ch == 0x08 || ch == 0x7F {
                if !bytes.isEmpty { bytes.removeLast() }
                continue
            }
            if ch < 0x20 { continue } // ignore other control characters
            bytes.append(UInt8(truncatingIfNeeded: ch))
        }
        if isTTY {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            print()
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
