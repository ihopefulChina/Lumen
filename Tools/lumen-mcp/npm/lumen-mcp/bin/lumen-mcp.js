#!/usr/bin/env node
'use strict';

// lumen-mcp npm 启动器：根据平台拉起对应的 Swift 预编译二进制，stdio 透传。
// 该包不含任何运行时依赖；平台二进制由 optionalDependencies 提供。

const { spawnSync } = require('child_process');
const os = require('os');
const path = require('path');

if (process.platform !== 'darwin') {
  console.error('lumen-mcp 目前仅支持 macOS（Lumen 是 Mac 应用）。');
  process.exit(1);
}

const platformPackage = `lumen-mcp-${process.platform}-${os.arch()}`;
let binaryPath;
try {
  binaryPath = require.resolve(`${platformPackage}/bin/lumen-mcp`);
} catch {
  console.error(
    `未找到平台包 ${platformPackage}（npm 安装时可能被 --no-optional 跳过）。\n` +
      '请重新安装：npm install -g lumen-mcp，或直接运行 npx --yes lumen-mcp'
  );
  process.exit(1);
}

// 运行上下文传给二进制：install 据此决定往客户端配置里写什么命令。
// - npx：配置写 "npx -y lumen-mcp"（不依赖缓存里的临时路径）
// - global：配置写 "lumen-mcp"（已在 PATH 上）
const viaNpx = __dirname.includes(`${path.sep}_npx${path.sep}`);
const result = spawnSync(binaryPath, process.argv.slice(2), {
  stdio: 'inherit',
  env: Object.assign({}, process.env, {
    LUMEN_MCP_INSTALLED_VIA: viaNpx ? 'npx' : 'global',
  }),
});
process.exit(result.status === null ? 1 : result.status);
