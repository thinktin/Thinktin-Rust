// 构建镜像时给 Playwright MCP 打的补丁（docs/browser.md 第 2.2 节第 5 条）：连 CDP 时不调 browser.bind()。
// bind() 会在 $XDG_RUNTIME_DIR/playwright 或 /tmp/pw-<hash>/ 下开一个 Unix socket，同一用户的任何进程都能连上、用完整的
// Playwright 接口（包括执行 JS），绕过 shim 的工具白名单。只有一个客户端（stdio）时用不到它。
// 用法：node patch-playwright.cjs <node_modules 目录>。补丁没有正好命中一处就失败（升级 Playwright 后要重新核对）。
'use strict';
const fs = require('fs');
const path = require('path');

const root = process.argv[2] || path.join(__dirname, 'node_modules');
const file = path.join(root, 'playwright-core', 'lib', 'coreBundle.js');
const before =
  'const { endpoint } = await browser.bind(bindOptions.title, { workspaceDir: bindOptions.workspaceDir });';
const after =
  'const { endpoint } = config.browser.cdpEndpoint ? { endpoint: void 0 } : ' +
  'await browser.bind(bindOptions.title, { workspaceDir: bindOptions.workspaceDir });';
const text = fs.readFileSync(file, 'utf8');
const hits = text.split(before).length - 1;
if (hits !== 1) {
  console.error(`expected exactly one bind() call to patch in ${file}, found ${hits}`);
  process.exit(1);
}
fs.writeFileSync(file, text.replace(before, after));
console.log(`patched ${file}`);
