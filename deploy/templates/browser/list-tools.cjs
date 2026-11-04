// 构建镜像时生成 tools.json（docs/browser.md 第 2.3 节第 2 条）：shim 一开始就把浏览器工具列给 agent，不用先起 Chromium。
// 用法：node list-tools.cjs > tools.json。工具名和 shim 的白名单（crates/agent-shim/src/browser/tools.rs 的 KEEP）由 CI 对照。
'use strict';
const { spawn } = require('child_process');
const path = require('path');

const cli = path.join(__dirname, 'node_modules', '@playwright', 'mcp', 'cli.js');
// 只列工具，不连浏览器：给一个连不上的地址也行。
const child = spawn(process.execPath, [cli, '--cdp-endpoint', 'ws://127.0.0.1:9/none', '--no-webmcp', '--codegen', 'none'], {
  stdio: ['pipe', 'pipe', 'inherit'],
});
let buf = '';
child.stdout.on('data', (d) => {
  buf += d;
  for (const line of buf.split('\n').slice(0, -1)) {
    const msg = JSON.parse(line);
    if (msg.id === 2) {
      process.stdout.write(JSON.stringify({ tools: msg.result.tools }, null, 2) + '\n');
      child.kill();
      process.exit(0);
    }
  }
  buf = buf.slice(buf.lastIndexOf('\n') + 1);
});
const send = (m) => child.stdin.write(JSON.stringify(m) + '\n');
send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'list-tools', version: '1' } } });
send({ jsonrpc: '2.0', method: 'notifications/initialized' });
send({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
setTimeout(() => {
  console.error('timed out listing tools');
  process.exit(1);
}, 30000);
