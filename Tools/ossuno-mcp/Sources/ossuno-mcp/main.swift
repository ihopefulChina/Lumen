import Foundation

// ossuno-mcp — standalone MCP server exposing Aliyun OSS operations to AI
// clients (Claude Desktop, Trae, Cursor, Codex, …) over stdio.
//
// Usage:
//   ossuno-mcp            start the MCP server (stdio transport)
//   ossuno-mcp auth       manage OSS credentials (keychain, interactive)
//   ossuno-mcp install    register into local MCP clients (one command)
//   ossuno-mcp uninstall  remove registrations
//   ossuno-mcp --version  print version

let arguments = Array(CommandLine.arguments.dropFirst())

let exitCode: Int32
switch arguments.first {
case "auth":
    exitCode = await AuthCommand.run(arguments: Array(arguments.dropFirst()))
case "install":
    exitCode = await InstallCommand.run(
        arguments: Array(arguments.dropFirst()), uninstalling: false)
case "uninstall":
    exitCode = await InstallCommand.run(arguments: Array(arguments.dropFirst()), uninstalling: true)
case "--version", "-V":
    print(OssunoMCPVersion.banner)
    exitCode = 0
case "--help", "-h":
    print(
        """
        ossuno-mcp — Ossuno 的 MCP 服务器，把阿里云 OSS 操作暴露给 AI 客户端（stdio）

        用法：
          ossuno-mcp                启动 MCP 服务器（由 AI 客户端拉起，无需手动运行）
          ossuno-mcp install        一键注册到本机已安装的 AI 客户端
          ossuno-mcp uninstall      移除注册
          ossuno-mcp auth           配置/管理 OSS 凭证
          ossuno-mcp auth --help    查看凭证管理子命令
          ossuno-mcp --version      显示版本

        支持的客户端：Claude Desktop、Claude Code、Cursor、Windsurf、Codex
        """)
    exitCode = 0
default:
    exitCode = await MCPServerCommand.run()
}
exit(exitCode)
