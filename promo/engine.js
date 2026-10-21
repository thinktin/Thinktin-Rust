// 逐帧动画的小工具集。所有画面都是时间 t 的纯函数：
// 每个镜头在 timeline.js 里注册 draw(t)，renderFrame(t) 依次调用。

const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const lerp = (a, b, x) => a + (b - a) * x;
// t 在 [a, b] 之间的进度，0..1
const prog = (t, a, b) => clamp((t - a) / (b - a));
// 进入、停留、退出：返回 0..1..0
const span = (t, inA, inB, outA, outB) => Math.min(prog(t, inA, inB), 1 - prog(t, outA, outB));

const ease = {
  linear: (x) => x,
  inCubic: (x) => x * x * x,
  outCubic: (x) => 1 - (1 - x) ** 3,
  inOutCubic: (x) => (x < 0.5 ? 4 * x * x * x : 1 - (-2 * x + 2) ** 3 / 2),
  outQuart: (x) => 1 - (1 - x) ** 4,
  outExpo: (x) => (x >= 1 ? 1 : 1 - 2 ** (-10 * x)),
  inExpo: (x) => (x <= 0 ? 0 : 2 ** (10 * x - 10)),
  inOutExpo: (x) =>
    x <= 0 ? 0 : x >= 1 ? 1 : x < 0.5 ? 2 ** (20 * x - 10) / 2 : (2 - 2 ** (-20 * x + 10)) / 2,
  outBack: (x) => {
    const c1 = 1.70158, c3 = c1 + 1;
    return 1 + c3 * (x - 1) ** 3 + c1 * (x - 1) ** 2;
  },
};

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

// 设置一个元素的透明度、位移、缩放、旋转和模糊
function pose(el, { o = 1, x = 0, y = 0, s = 1, sx, sy, r = 0, blur = 0 } = {}) {
  el.style.opacity = String(clamp(o));
  el.style.visibility = o <= 0.001 ? 'hidden' : 'visible';
  const scale = sx !== undefined || sy !== undefined ? `scale(${sx ?? s}, ${sy ?? s})` : `scale(${s})`;
  el.style.transform = `translate(${x}px, ${y}px) ${scale} rotate(${r}deg)`;
  el.style.filter = blur > 0.05 ? `blur(${blur}px)` : 'none';
}

// 把文字拆成逐字的 span，返回这些 span
function splitChars(el) {
  if (el._chars) return el._chars;
  const text = el.textContent;
  el.textContent = '';
  el._chars = [...text].map((c) => {
    const s = document.createElement('span');
    s.className = 'ch';
    s.textContent = c === ' ' ? ' ' : c;
    el.appendChild(s);
    return s;
  });
  return el._chars;
}

// 逐字上浮出现、整体淡出
function revealChars(el, t, start, { stagger = 0.035, dur = 0.5, rise = 40, out = Infinity, outDur = 0.35 } = {}) {
  const chars = splitChars(el);
  const o = 1 - ease.inCubic(prog(t, out, out + outDur));
  chars.forEach((c, i) => {
    const k = ease.outExpo(prog(t, start + i * stagger, start + i * stagger + dur));
    pose(c, { o: k * o, y: (1 - k) * rise - (1 - o) * 16, blur: (1 - k) * 8 });
  });
  el.style.visibility = 'visible';
}

// SVG 描边动画：k 为 0..1
function drawStroke(path, k) {
  const len = path._len ?? (path._len = path.getTotalLength());
  path.style.strokeDasharray = `${len} ${len}`;
  path.style.strokeDashoffset = String(len * (1 - k));
}

// 沿路径取点，k 为 0..1
function pointAt(path, k) {
  const len = path._len ?? (path._len = path.getTotalLength());
  return path.getPointAtLength(clamp(k) * len);
}

// 可复现的伪随机数
function rand(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let x = s;
    x = Math.imul(x ^ (x >>> 15), x | 1);
    x ^= x + Math.imul(x ^ (x >>> 7), x | 61);
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
}

const scenes = [];
function scene(start, end, draw) {
  scenes.push({ start, end, draw });
}

// 每一帧调用一次。镜头之外的时间也会调用，方便镜头自己处理淡入淡出。
window.renderFrame = (t) => {
  for (const sc of scenes) {
    const active = t >= sc.start - 0.0001 && t < sc.end;
    sc.el ??= document.querySelector(`[data-scene="${scenes.indexOf(sc)}"]`);
    if (sc.el) sc.el.style.display = active ? 'block' : 'none';
    if (active) sc.draw(t, t - sc.start);
  }
  window.drawGlobal?.(t);
};

// 浏览器里直接打开 index.html 时：实时播放，带进度条和音乐
window.addEventListener('DOMContentLoaded', () => {
  const rendering = new URLSearchParams(location.search).has('render');
  const fit = () => {
    const k = Math.min(innerWidth / 1920, innerHeight / 1080);
    document.documentElement.style.setProperty('--fit', rendering ? 1 : k);
  };
  fit();
  addEventListener('resize', fit);
  if (rendering) {
    window.renderFrame(0);
    return;
  }

  document.body.classList.add('preview');
  const bar = document.createElement('div');
  bar.id = 'scrub';
  bar.innerHTML = '<button id="play">▶</button><input id="pos" type="range" min="0" step="0.01"><span id="clock">0.00</span>';
  document.body.appendChild(bar);
  const pos = $('#pos'), clock = $('#clock'), btn = $('#play');
  pos.max = window.DURATION;
  const audio = new Audio('out/music.wav');
  let playing = false, t0 = 0, base = 0;
  const show = (t) => {
    window.renderFrame(t);
    pos.value = t;
    clock.textContent = t.toFixed(2);
  };
  const tick = (now) => {
    if (!playing) return;
    const t = base + (now - t0) / 1000;
    if (t >= window.DURATION) {
      playing = false;
      btn.textContent = '▶';
      audio.pause();
      show(window.DURATION - 1 / 30);
      return;
    }
    show(t);
    requestAnimationFrame(tick);
  };
  const play = () => {
    if (Number(pos.value) >= window.DURATION - 0.05) pos.value = 0;
    base = Number(pos.value);
    t0 = performance.now();
    playing = true;
    btn.textContent = '❚❚';
    audio.currentTime = base;
    audio.play().catch(() => {});
    requestAnimationFrame(tick);
  };
  const pause = () => {
    playing = false;
    btn.textContent = '▶';
    audio.pause();
  };
  btn.onclick = () => (playing ? pause() : play());
  pos.oninput = () => {
    pause();
    show(Number(pos.value));
  };
  addEventListener('keydown', (e) => {
    if (e.code === 'Space') {
      e.preventDefault();
      playing ? pause() : play();
    }
  });
  document.fonts.ready.then(() => show(0));
});
