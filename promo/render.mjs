// 逐帧渲染 index.html，经 ffmpeg 编码成 MP4。
//
//   node render.mjs                     渲染整片到 out/thinktin-promo.mp4
//   node render.mjs --stills 1,4.5,18   只导出指定时间点的静帧到 out/stills/
//
// 画面由页面里的 window.renderFrame(t) 按时间 t 确定性地画出，
// 不依赖 CSS 动画或真实时钟，所以每次渲染结果一致。

import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdirSync, existsSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : fallback;
};

const FPS = Number(opt('fps', 30));
const WIDTH = 1920;
const HEIGHT = 1080;
const OUT = opt('out', join(here, 'out', 'thinktin-promo.mp4'));
const AUDIO = opt('audio', join(here, 'out', 'music.wav'));
const STILLS = opt('stills', null);

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_PATH || undefined,
  args: ['--font-render-hinting=none', '--disable-lcd-text'],
});
const page = await browser.newPage({
  viewport: { width: WIDTH, height: HEIGHT },
  deviceScaleFactor: 1,
});
page.on('pageerror', (e) => {
  console.error('page error:', e);
  process.exitCode = 1;
});
await page.goto(pathToFileURL(join(here, 'index.html')).href + '?render=1');
await page.evaluate(() => document.fonts.ready);
const DURATION = await page.evaluate(() => window.DURATION);

const draw = async (t) => {
  await page.evaluate((t) => window.renderFrame(t), t);
  return page.screenshot({ type: 'png', animations: 'disabled', caret: 'hide' });
};

if (STILLS) {
  const dir = join(here, 'out', 'stills');
  mkdirSync(dir, { recursive: true });
  for (const s of STILLS.split(',').map(Number)) {
    const file = join(dir, `t${s.toFixed(2).padStart(5, '0')}.png`);
    writeFileSync(file, await draw(s));
    console.log(file);
  }
  await browser.close();
  process.exit(process.exitCode ?? 0);
}

mkdirSync(dirname(OUT), { recursive: true });
const withAudio = existsSync(AUDIO);
if (!withAudio) console.warn(`没有找到 ${AUDIO}，输出无声版本（先运行 python3 music.py）`);

const ffmpeg = spawn(
  'ffmpeg',
  [
    '-y', '-loglevel', 'error',
    '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'png', '-i', '-',
    ...(withAudio ? ['-i', AUDIO] : []),
    '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '18', '-profile:v', 'high',
    '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709',
    ...(withAudio ? ['-c:a', 'aac', '-b:a', '192k'] : []),
    '-t', String(DURATION),
    '-movflags', '+faststart',
    OUT,
  ],
  { stdio: ['pipe', 'inherit', 'inherit'] },
);
const done = new Promise((resolve, reject) => {
  ffmpeg.on('error', reject);
  ffmpeg.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`ffmpeg 退出码 ${code}`))));
});

const total = Math.round(DURATION * FPS);
for (let f = 0; f < total; f++) {
  const png = await draw(f / FPS);
  if (!ffmpeg.stdin.write(png)) await new Promise((r) => ffmpeg.stdin.once('drain', r));
  if (f % FPS === 0) process.stdout.write(`\r渲染 ${f}/${total}`);
}
ffmpeg.stdin.end();
await done;
await browser.close();
console.log(`\r渲染完成：${OUT}`);
