// Playwright MCP 的启动脚本（docs/browser.md 第 2.6 节）。agent-shim 把 CDP 前置口的地址（带秘密路径）写进 fd 3：
// 地址不出现在命令行和启动时的环境里（同一个用户能读 /proc/<pid>/cmdline 和 environ；运行中才设的环境变量不在
// environ 里）。读完设进 PLAYWRIGHT_MCP_CDP_ENDPOINT，再加载 Playwright MCP 本体；命令行参数原样交给它。
'use strict';
const fs = require('fs');
const path = require('path');

let endpoint = '';
try {
  endpoint = fs.readFileSync(3, 'utf8').trim();
  fs.closeSync(3);
} catch (e) {
  // 下面报错退出。
}
if (!/^ws:\/\/127\.0\.0\.1:\d+\/[0-9a-f]{64}$/.test(endpoint)) {
  process.stderr.write('thinktin: no CDP endpoint on fd 3\n');
  process.exit(2);
}
process.env.PLAYWRIGHT_MCP_CDP_ENDPOINT = endpoint;
require(path.join(__dirname, 'node_modules', '@playwright', 'mcp', 'cli.js'));
