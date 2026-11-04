// Playwright MCP 的启动脚本（docs/browser.md 第 2.6 节）。agent-shim 把 CDP 前置口的地址和秘密写进 fd 3（两行）：它们不出现
// 在命令行和启动时的环境里（同一个用户能读 /proc/<pid>/cmdline 和 environ；运行中才设的环境变量不在 environ 里）。秘密放在
// 请求头里，不放网址里：Playwright 连不上时会把网址写进错误、交给 agent。读完设进环境变量，再加载 Playwright MCP 本体；
// 命令行参数原样交给它。
'use strict';
const fs = require('fs');
const path = require('path');

// 内存不够时系统先杀浏览器，不杀 agent（shim 不可转储，exec 之前写不了，只能这里写）。
try {
  fs.writeFileSync('/proc/self/oom_score_adj', '500');
} catch (e) {
  // 写不了也接着起。
}

let endpoint = '';
let secret = '';
try {
  [endpoint = '', secret = ''] = fs.readFileSync(3, 'utf8').split('\n').map((l) => l.trim());
  fs.closeSync(3);
} catch (e) {
  // 下面报错退出。
}
if (!/^ws:\/\/127\.0\.0\.1:\d+\/$/.test(endpoint) || !/^[0-9a-f]{64}$/.test(secret)) {
  process.stderr.write('thinktin: no CDP endpoint on fd 3\n');
  process.exit(2);
}
process.env.PLAYWRIGHT_MCP_CDP_ENDPOINT = endpoint;
process.env.PLAYWRIGHT_MCP_CDP_HEADERS = `X-Thinktin-Front: ${secret}`;
require(path.join(__dirname, 'node_modules', '@playwright', 'mcp', 'cli.js'));
