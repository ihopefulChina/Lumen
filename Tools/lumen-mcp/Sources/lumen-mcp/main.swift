import Foundation

// lumen-mcp — standalone MCP server exposing Aliyun OSS operations to AI
// clients (Claude Desktop, Trae, Cursor, …) over stdio.
//
// Usage:
//   lumen-mcp            start the MCP server (stdio transport)
//   lumen-mcp auth       manage OSS credentials (keychain, interactive)
//   lumen-mcp --version  print version

let arguments = Array(CommandLine.arguments.dropFirst())

let exitCode: Int32
switch arguments.first {
case "auth":
    exitCode = await AuthCommand.run(arguments: Array(arguments.dropFirst()))
case "--version", "-V":
    print("lumen-mcp 1.0.0")
    exitCode = 0
case "--help", "-h":
    print("""
    lumen-mcp — Lumen 的 MCP 服务器，把阿里云 OSS 操作暴露给 AI 客户端（stdio）

    用法：
      lumen-mcp              启动 MCP 服务器（由 AI 客户端拉起，无需手动运行）
      lumen-mcp auth         配置/管理 OSS 凭证
      lumen-mcp auth --help  查看凭证管理子命令
      lumen-mcp --version    显示版本
    """)
    exitCode = 0
default:
    exitCode = await MCPServerCommand.run()
}
exit(exitCode)
