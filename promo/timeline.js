// 分镜：六个镜头。切换点和 music.py 里的 CUES / LOGO 对齐（120 BPM）。
//
//   0.0– 3.5  01 常驻云端：退出登录后，云端 agent 按计划跑完，早上推送送达
//   3.5– 6.5  02 多 agent 协同：编排服务按 DAG 调度，经产出物交接
//   6.5–10.0  03 强隔离：每个 agent 一台 microVM，key 只在模型网关里换上
//  10.0–13.0  04 手机控制电脑：高危操作经设备中继回到手机签名
//  13.0–16.0  05 Rust 内核、三端原生：client-core + 16 个 crate
//  16.0–20.0  06 品牌落版

window.DURATION = 20;
const CUT = [0, 3.5, 6.5, 10, 13, 16, 20];

const C = {
  text: '#eaf0ff',
  dim: '#7d8aa8',
  line: '#2b3757',
  panel: '#0d1427',
  cyan: '#3de0ff',
  violet: '#8b7cff',
  pink: '#ff6fb1',
  mint: '#3dffb0',
  amber: '#ffb547',
  red: '#ff5c7a',
};

// ---------- SVG 构造工具 ----------

const NS = 'http://www.w3.org/2000/svg';
function h(tag, attrs = {}, ...kids) {
  const el = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'text') el.textContent = v;
    else el.setAttribute(k, v);
  }
  for (const k of kids.flat(Infinity)) if (k) el.appendChild(k);
  return el;
}
const add = (parent, ...kids) => parent.append(...kids.flat(Infinity).filter(Boolean));
const at = (x, y, ...kids) => h('g', { transform: `translate(${x} ${y})` }, ...kids);
const pop = (attrs, ...kids) => h('g', { class: 'pop', ...attrs }, ...kids);
const rr = (x, y, w, hh, r) =>
  `M ${x + r} ${y} H ${x + w - r} A ${r} ${r} 0 0 1 ${x + w} ${y + r} V ${y + hh - r} ` +
  `A ${r} ${r} 0 0 1 ${x + w - r} ${y + hh} H ${x + r} A ${r} ${r} 0 0 1 ${x} ${y + hh - r} ` +
  `V ${y + r} A ${r} ${r} 0 0 1 ${x + r} ${y} Z`;
const ring = (r) => `M 0 ${-r} A ${r} ${r} 0 1 1 0 ${r} A ${r} ${r} 0 1 1 0 ${-r}`;
const text = (x, y, s, attrs = {}) => h('text', { x, y, fill: C.text, 'font-size': 22, ...attrs, text: s });
const check = (stroke = '#05120c', w = 4, s = 1) =>
  h('path', {
    d: `M ${-7 * s} 0 L ${-2 * s} ${6 * s} L ${8 * s} ${-6 * s}`,
    fill: 'none', stroke, 'stroke-width': w, 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
  });
const okBadge = (x, y, id) => at(x, y, pop({ id }, h('circle', { r: 17, fill: C.mint }), check()));
const agent = (size, color, attrs = {}) =>
  h('use', { href: '#g-agent', x: -size / 2, y: -size / 2, width: size, height: size, style: `color:${color}`, ...attrs });
const docIcon = (color) =>
  h('g', {},
    h('path', { d: rr(-12, -15, 24, 30, 5), fill: color }),
    h('path', { d: 'M -6 -6 H 6 M -6 0 H 6 M -6 6 H 2', stroke: '#05070d', 'stroke-width': 2.5, 'stroke-linecap': 'round' }));
const lockIcon = (color) =>
  h('g', {},
    h('path', { d: rr(-7, -2, 14, 11, 2.5), fill: color }),
    h('path', { d: 'M -4.5 -2 V -5.5 A 4.5 4.5 0 0 1 4.5 -5.5 V -2', fill: 'none', stroke: color, 'stroke-width': 2.5 }));
const move = (el, x, y) => el.setAttribute('transform', `translate(${x} ${y})`);
const popIn = (el, u, start, dur = 0.4, from = 0.5) => {
  const k = ease.outBack(prog(u, start, start + dur));
  pose(el, { o: prog(u, start, start + dur * 0.4), s: from + (1 - from) * k });
};

// ---------- 文字与退场 ----------

function drawCopy(sec, t, s, e) {
  const out = e - 0.34;
  const ko = ease.inCubic(prog(t, out, e - 0.04));
  const ki = ease.outExpo(prog(t, s + 0.02, s + 0.6));
  pose($('.idx', sec), { o: ki * (1 - ko), x: (1 - ki) * -40 });
  for (const l of $$('h1 .l', sec)) {
    revealChars(l, t, s + Number(l.dataset.at), { out, outDur: 0.3, rise: 56, stagger: 0.04, dur: 0.6 });
  }
  const sub = $('.sub', sec);
  const at0 = s + Number(sub.dataset.at);
  const ks = ease.outCubic(prog(t, at0, at0 + 0.5));
  pose(sub, { o: ks * (1 - ko), y: (1 - ks) * 24, blur: (1 - ks) * 6 });
}

function exitVis(svg, t, e) {
  const ko = ease.inCubic(prog(t, e - 0.34, e - 0.04));
  pose(svg, { o: 1 - ko, s: 1 + 0.05 * ko, blur: ko * 10 });
}

// ---------- 01 常驻云端 ----------

function build1() {
  const phone = at(150, 150, pop({ id: 's1-phone' },
    h('path', { d: rr(0, 0, 240, 480, 40), fill: '#0a0f1e', stroke: C.line, 'stroke-width': 3 }),
    h('path', { d: rr(12, 12, 216, 456, 30), fill: 'url(#scr)' }),
    h('path', { d: rr(30, 72, 132, 36, 18), fill: '#1a2542' }),
    h('path', { d: rr(84, 122, 124, 36, 18), fill: C.cyan, 'fill-opacity': 0.22 }),
    h('path', { d: rr(30, 172, 160, 60, 20), fill: '#1a2542' }),
    h('path', { d: rr(112, 246, 96, 36, 18), fill: C.cyan, 'fill-opacity': 0.22 }),
    h('path', { d: rr(30, 296, 120, 36, 18), fill: '#1a2542' }),
    h('path', { d: rr(28, 412, 184, 40, 20), fill: '#10182f', stroke: '#24304f' }),
    h('path', { id: 's1-dim', d: rr(12, 12, 216, 456, 30), fill: '#03050b', opacity: 0 }),
    h('g', { id: 's1-moon', opacity: 0 },
      h('circle', { cx: 120, cy: 210, r: 26, fill: '#a9b6d6' }),
      h('circle', { cx: 132, cy: 200, r: 22, fill: '#03050b' })),
    at(120, 336, pop({ id: 's1-toast' },
      h('path', { d: rr(-96, -28, 192, 56, 28), fill: '#1a2443', stroke: '#3a4775' }),
      text(0, 8, '已退出登录', { 'text-anchor': 'middle' }))),
    at(120, 120, pop({ id: 's1-push' },
      h('path', { d: rr(-100, -44, 200, 88, 20), fill: '#141d36', stroke: C.mint, 'stroke-opacity': 0.5 }),
      at(-66, 0, h('circle', { r: 17, fill: C.mint }), check()),
      text(-38, -6, '任务已完成', { 'font-weight': 700 }),
      text(-38, 22, '07:00 · 已送达', { class: 'mono', 'font-size': 15, fill: C.dim }))),
    h('path', { d: rr(92, 22, 56, 10, 5), fill: '#1c2642' }),
  ));

  const cloud = at(620, 300, pop({ id: 's1-cloud' },
    h('circle', { id: 's1-ring', r: 150, fill: 'none', stroke: C.cyan, 'stroke-opacity': 0.35, 'stroke-width': 2, 'stroke-dasharray': '3 11' }),
    h('circle', { r: 112, fill: 'none', stroke: C.violet, 'stroke-opacity': 0.3, 'stroke-width': 2 }),
    h('circle', { id: 's1-arc', r: 112, fill: 'none', stroke: 'url(#gCV)', 'stroke-width': 5, 'stroke-linecap': 'round', 'stroke-dasharray': '150 554' }),
    h('circle', { id: 's1-core', r: 96, fill: 'url(#rCore)' }),
    agent(116, C.cyan, { filter: 'url(#glow)' }),
  ));

  const badge = at(620, 488, pop({ id: 's1-badge' },
    h('path', { d: rr(-78, -24, 156, 48, 24), fill: '#0b1a22', stroke: C.mint, 'stroke-opacity': 0.5 }),
    h('circle', { id: 's1-dot', cx: -40, r: 7, fill: C.mint }),
    text(-22, 8, '运行中', { fill: C.mint, 'font-weight': 700 })));

  const times = ['01:00', '03:00', '05:00', '07:00'];
  const tl = h('g', { id: 's1-tl', opacity: 0 },
    h('line', { x1: 470, y1: 662, x2: 770, y2: 662, stroke: C.line, 'stroke-width': 2 }),
    h('line', { id: 's1-tlp', x1: 470, y1: 662, x2: 470, y2: 662, stroke: C.cyan, 'stroke-width': 3 }),
    times.map((s, i) =>
      h('g', {},
        h('circle', { id: `s1-r${i}`, cx: 470 + i * 100, cy: 662, r: 7, fill: 'none', stroke: C.cyan, 'stroke-width': 2, opacity: 0 }),
        h('circle', { id: `s1-d${i}`, cx: 470 + i * 100, cy: 662, r: 7, fill: C.line }),
        text(470 + i * 100, 698, s, { class: 'mono', 'font-size': 15, fill: C.dim, 'text-anchor': 'middle' }))));

  add($('#v1'),
    h('path', { id: 's1-link', d: 'M 392 330 C 440 330 456 300 506 300', fill: 'none', stroke: C.cyan, 'stroke-width': 3, 'stroke-linecap': 'round' }),
    phone, cloud, badge,
    text(620, 606, '23:00', { id: 's1-clock', class: 'mono', 'font-size': 72, 'text-anchor': 'middle' }),
    tl,
  );
}

function draw1(t, u) {
  const kp = ease.outExpo(prog(u, 0, 0.7));
  pose($('#s1-phone'), { o: prog(u, 0, 0.3), y: (1 - kp) * 80 });
  popIn($('#s1-cloud'), u, 0.15, 0.6, 0.55);
  $('#s1-ring').setAttribute('transform', `rotate(${u * 30})`);
  const spin = u * 140 + 900 * ease.inOutCubic(prog(u, 1.0, 2.4));
  $('#s1-arc').setAttribute('transform', `rotate(${spin - 90})`);
  $('#s1-core').setAttribute('r', 96 + 8 * Math.sin(u * 5));

  // 手机和云端连着，退出登录后断开，云端照跑
  const link = $('#s1-link');
  drawStroke(link, ease.outCubic(prog(u, 0.35, 0.75)));
  link.style.opacity = String(1 - 0.85 * prog(u, 1.0, 1.3));
  const kt = ease.outBack(prog(u, 0.55, 0.85));
  pose($('#s1-toast'), { o: prog(u, 0.55, 0.7) * (1 - prog(u, 1.05, 1.2)), s: 0.85 + 0.15 * kt });
  const dim = ease.inOutCubic(prog(u, 0.95, 1.25)) - 0.5 * ease.outCubic(prog(u, 2.35, 2.6));
  $('#s1-dim').setAttribute('opacity', dim);
  $('#s1-moon').setAttribute('opacity', prog(u, 1.15, 1.4) * (1 - prog(u, 2.3, 2.45)));

  popIn($('#s1-badge'), u, 0.5, 0.35, 0.7);
  $('#s1-dot').setAttribute('opacity', 0.45 + 0.55 * (0.5 + 0.5 * Math.cos(u * 9)));

  // 时钟快进 23:00 → 07:00，计划逐个触发
  const kk = ease.inOutCubic(prog(u, 1.0, 2.4));
  const mins = (23 * 60 + Math.round(480 * kk)) % 1440;
  const clock = $('#s1-clock');
  clock.textContent = `${String(Math.floor(mins / 60)).padStart(2, '0')}:${String(mins % 60).padStart(2, '0')}`;
  pose(clock, { o: prog(u, 0.75, 1.0), y: (1 - ease.outCubic(prog(u, 0.75, 1.0))) * 20 });
  $('#s1-tl').setAttribute('opacity', prog(u, 0.8, 1.05));
  $('#s1-tlp').setAttribute('x2', 470 + 300 * clamp((kk - 0.25) / 0.75));
  for (let i = 0; i < 4; i++) {
    const th = 0.25 * (i + 1) - 1e-6;
    $(`#s1-d${i}`).setAttribute('fill', kk >= th ? C.cyan : C.line);
    const rp = clamp((kk - th) / 0.15);
    const r = $(`#s1-r${i}`);
    r.setAttribute('r', 7 + 20 * rp);
    r.setAttribute('opacity', kk >= th ? 1 - rp : 0);
  }

  const kq = ease.outBack(prog(u, 2.4, 2.75));
  pose($('#s1-push'), { o: prog(u, 2.4, 2.55), y: (1 - kq) * -36, s: 0.9 + 0.1 * kq });
}

// ---------- 02 多 agent 协同 ----------

const ICON = {
  search: (c) => h('g', {},
    h('circle', { cx: -6, cy: -6, r: 18, fill: 'none', stroke: c, 'stroke-width': 6 }),
    h('path', { d: 'M 8 8 L 22 22', stroke: c, 'stroke-width': 7, 'stroke-linecap': 'round' })),
  code: (c) => h('path', {
    d: 'M -14 -18 L -30 0 L -14 18 M 14 -18 L 30 0 L 14 18 M 5 -24 L -5 24',
    fill: 'none', stroke: c, 'stroke-width': 6, 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
  }),
  doc: (c) => h('g', {},
    h('path', { d: rr(-20, -26, 40, 52, 7), fill: 'none', stroke: c, 'stroke-width': 5 }),
    h('path', { d: 'M -10 -10 H 10 M -10 2 H 10 M -10 14 H 3', stroke: c, 'stroke-width': 4, 'stroke-linecap': 'round' })),
  chart: (c) => h('path', { d: 'M -24 22 V 6 M -8 22 V -10 M 8 22 V 0 M 24 22 V -22', stroke: c, 'stroke-width': 8, 'stroke-linecap': 'round' }),
};

const S2 = {
  nodes: [
    { id: 'a', x: 130, y: 430, name: '调研', color: C.cyan, icon: 'search', in: 0.12, work: [0.55, 0.95] },
    { id: 'b', x: 450, y: 300, name: '编码', color: C.violet, icon: 'code', in: 0.26, work: [1.35, 1.75] },
    { id: 'c', x: 450, y: 580, name: '撰写', color: C.pink, icon: 'doc', in: 0.32, work: [1.35, 1.75] },
    { id: 'd', x: 770, y: 430, name: '汇总', color: C.mint, icon: 'chart', in: 0.46, work: [2.1, 2.4] },
  ],
  edges: [
    { id: 'ab', d: 'M 206 410 C 290 410 300 300 374 300', color: C.cyan, go: [0.95, 1.35] },
    { id: 'ac', d: 'M 206 450 C 290 450 300 580 374 580', color: C.cyan, go: [0.95, 1.35] },
    { id: 'bd', d: 'M 526 300 C 600 300 610 410 694 410', color: C.violet, go: [1.75, 2.1] },
    { id: 'cd', d: 'M 526 580 C 600 580 610 450 694 450', color: C.pink, go: [1.75, 2.1] },
  ],
  hubLines: ['M 380 150 L 160 362', 'M 450 150 L 450 232', 'M 520 150 L 740 362'],
};

function build2() {
  const v = $('#v2');
  add(v,
    h('g', { id: 's2-hl' }, S2.hubLines.map((d) =>
      h('path', { d, fill: 'none', stroke: C.violet, 'stroke-opacity': 0.55, 'stroke-width': 2, 'stroke-dasharray': '5 9' }))),
    at(450, 110, pop({ id: 's2-hub' },
      h('path', { d: rr(-150, -40, 300, 80, 40), fill: '#0e1630', stroke: C.violet, 'stroke-opacity': 0.8, 'stroke-width': 2 }),
      text(0, -2, '编排服务', { 'text-anchor': 'middle', 'font-size': 26, 'font-weight': 700 }),
      text(0, 24, 'orchestrator', { 'text-anchor': 'middle', class: 'mono', 'font-size': 15, fill: C.dim }))),
    S2.edges.map((e) => h('g', {},
      h('path', { id: `s2-e-${e.id}`, d: e.d, fill: 'none', stroke: '#34406a', 'stroke-width': 3, 'stroke-linecap': 'round' }),
      h('path', { id: `s2-f-${e.id}`, d: e.d, fill: 'none', stroke: e.color, 'stroke-width': 3, 'stroke-linecap': 'round' }))),
    text(250, 556, '产出物', { id: 's2-art', 'font-size': 18, fill: C.dim, 'text-anchor': 'middle' }),
    S2.nodes.map((n) => at(n.x, n.y, pop({ id: `s2-${n.id}` },
      h('path', { d: rr(-64, -64, 128, 128, 32), fill: C.panel, stroke: C.line, 'stroke-width': 3 }),
      h('path', { id: `s2-${n.id}-ring`, d: rr(-76, -76, 152, 152, 40), fill: 'none', stroke: n.color, 'stroke-width': 3, 'stroke-linecap': 'round' }),
      pop({ id: `s2-${n.id}-ic` }, ICON[n.icon](n.color)),
      text(0, 112, n.name, { 'text-anchor': 'middle', 'font-size': 26, 'font-weight': 700 }),
      okBadge(58, -58, `s2-${n.id}-ok`)))),
    S2.edges.map((e) => h('g', { id: `s2-p-${e.id}`, filter: 'url(#glow)' }, docIcon(e.color))),
  );
}

function draw2(t, u) {
  popIn($('#s2-hub'), u, 0, 0.45, 0.8);
  const hl = $('#s2-hl');
  hl.setAttribute('opacity', prog(u, 0.35, 0.7));
  for (const p of $$('path', hl)) p.style.strokeDashoffset = String(-u * 40);

  S2.edges.forEach((e, i) => {
    drawStroke($(`#s2-e-${e.id}`), ease.outCubic(prog(u, 0.5 + i * 0.05, 1.0 + i * 0.05)));
    const k = ease.inOutCubic(prog(u, e.go[0], e.go[1]));
    drawStroke($(`#s2-f-${e.id}`), k);
    const p = $(`#s2-p-${e.id}`);
    const pt = pointAt($(`#s2-e-${e.id}`), k);
    move(p, pt.x, pt.y);
    p.setAttribute('opacity', span(u, e.go[0], e.go[0] + 0.08, e.go[1] - 0.04, e.go[1] + 0.06));
  });
  $('#s2-art').setAttribute('opacity', prog(u, 1.05, 1.3));

  for (const n of S2.nodes) {
    popIn($(`#s2-${n.id}`), u, n.in, 0.45, 0.6);
    const [w0, w1] = n.work;
    drawStroke($(`#s2-${n.id}-ring`), ease.inOutCubic(prog(u, w0, w1)));
    const busy = u >= w0 && u < w1 ? Math.sin(((u - w0) / (w1 - w0)) * Math.PI) : 0;
    pose($(`#s2-${n.id}-ic`), { s: 1 + 0.12 * busy });
    popIn($(`#s2-${n.id}-ok`), u, w1, 0.3, 0.3);
  }
}

// ---------- 03 强隔离 ----------

const S3 = { colors: [C.cyan, C.violet, C.mint], xs: [30, 335, 640] };

function build3() {
  const v = $('#v3');
  const boxes = S3.xs.map((x, i) => at(x, 110, pop({ id: `s3-b${i}` },
    h('path', { d: rr(0, 0, 230, 280, 26), fill: '#0b1124', stroke: '#253152', 'stroke-width': 2 }),
    h('path', { id: `s3-s${i}`, d: rr(-12, -12, 254, 304, 36), fill: 'none', stroke: 'url(#gCV)', 'stroke-width': 3 }),
    text(24, 42, 'microVM', { class: 'mono', 'font-size': 17, fill: C.dim }),
    at(115, 156, agent(118, S3.colors[i])),
    at(196, 36, pop({ id: `s3-l${i}` }, h('circle', { r: 17, fill: '#0e1a24', stroke: C.mint, 'stroke-width': 2 }), lockIcon(C.mint))))));
  const walls = [297.5, 602.5].map((x, j) => at(x, 250, pop({ id: `s3-x${j}` },
    h('circle', { r: 17, fill: '#1c0e18', stroke: C.red, 'stroke-width': 2 }),
    h('path', { d: 'M -6 -6 L 6 6 M 6 -6 L -6 6', stroke: C.red, 'stroke-width': 3, 'stroke-linecap': 'round' }))));
  const wires = S3.xs.map((x) =>
    h('line', { x1: x + 115, y1: 404, x2: x + 115, y2: 518, stroke: '#3a4775', 'stroke-width': 2, 'stroke-dasharray': '4 7' }));
  const tokens = S3.xs.map((x, i) => at(x + 115, 404, h('g', { id: `s3-t${i}` },
    h('path', { d: rr(-30, -15, 60, 30, 15), fill: '#13203a', stroke: C.cyan, 'stroke-width': 1.5 }),
    text(0, 6, '令牌', { 'text-anchor': 'middle', 'font-size': 15, fill: C.cyan }))));
  const gateway = pop({ id: 's3-gw' },
    h('path', { d: rr(60, 520, 780, 96, 26), fill: '#0d1630', stroke: C.cyan, 'stroke-width': 2 }),
    text(100, 580, '模型网关', { 'font-size': 30, 'font-weight': 700 }),
    text(236, 578, 'llm-gw', { class: 'mono', 'font-size': 16, fill: C.dim }),
    text(738, 576, '你的 key', { 'text-anchor': 'end', 'font-size': 20, fill: C.amber }),
    at(776, 568, h('g', { id: 's3-key' },
      h('circle', { cx: -12, r: 10, fill: 'none', stroke: C.amber, 'stroke-width': 5 }),
      h('path', { d: 'M -2 0 H 24 M 16 0 V 9 M 23 0 V 7', fill: 'none', stroke: C.amber, 'stroke-width': 5, 'stroke-linecap': 'round' }))));
  const vendor = h('g', { id: 's3-vd' },
    h('line', { x1: 450, y1: 618, x2: 450, y2: 688, stroke: '#3a4775', 'stroke-width': 2 }),
    h('path', { d: rr(290, 690, 320, 58, 29), fill: '#0b1124', stroke: '#3a4775', 'stroke-width': 2 }),
    text(450, 727, '任意模型厂商', { 'text-anchor': 'middle' }));
  const packet = h('circle', { id: 's3-pk', cx: 450, cy: 618, r: 7, fill: C.amber, filter: 'url(#glow)' });
  add(v, h('g', { id: 's3-w' }, wires), boxes, walls, vendor, gateway, tokens, packet);
}

function draw3(t, u) {
  S3.xs.forEach((_, i) => {
    const st = 0.05 + i * 0.1;
    const k = ease.outExpo(prog(u, st, st + 0.6));
    pose($(`#s3-b${i}`), { o: prog(u, st, st + 0.25), y: (1 - k) * 70 });
    drawStroke($(`#s3-s${i}`), ease.inOutCubic(prog(u, 0.4 + i * 0.1, 1.0 + i * 0.1)));
    popIn($(`#s3-l${i}`), u, 0.95 + i * 0.08, 0.3, 0.3);
    const kt = ease.inOutCubic(prog(u, 1.9 + i * 0.08, 2.35 + i * 0.08));
    const tk = $(`#s3-t${i}`);
    move(tk, 0, 100 * kt);
    tk.setAttribute('opacity', span(u, 1.9 + i * 0.08, 2.0 + i * 0.08, 2.3 + i * 0.08, 2.4 + i * 0.08));
  });
  [0, 1].forEach((j) => popIn($(`#s3-x${j}`), u, 1.1 + j * 0.08, 0.3, 0.3));
  const kg = ease.outExpo(prog(u, 1.2, 1.7));
  pose($('#s3-gw'), { o: prog(u, 1.2, 1.4), y: (1 - kg) * 40 });
  $('#s3-w').setAttribute('opacity', prog(u, 1.45, 1.7));
  const kk = ease.outExpo(prog(u, 1.6, 2.1));
  const key = $('#s3-key');
  move(key, (1 - kk) * 160, 0);
  key.setAttribute('opacity', prog(u, 1.6, 1.8));
  $('#s3-vd').setAttribute('opacity', prog(u, 2.2, 2.45));
  const kp = ease.inOutCubic(prog(u, 2.45, 2.85));
  const pk = $('#s3-pk');
  pk.setAttribute('cy', 618 + 70 * kp);
  pk.setAttribute('opacity', span(u, 2.45, 2.5, 2.8, 2.9));
}

// ---------- 04 手机控制电脑 ----------

function build4() {
  const v = $('#v4');
  const fp = h('g', {}, [10, 18, 26].map((r) =>
    h('path', { d: `M ${-r} 6 A ${r} ${r} 0 0 1 ${r} 6`, fill: 'none', stroke: '#5a6890', 'stroke-width': 3.5, 'stroke-linecap': 'round' })),
  h('path', { d: 'M -26 14 A 26 26 0 0 0 -8 30 M 0 2 V 24', fill: 'none', stroke: '#5a6890', 'stroke-width': 3.5, 'stroke-linecap': 'round' }));
  const phone = at(30, 170, pop({ id: 's4-phone' },
    h('path', { d: rr(0, 0, 220, 440, 36), fill: '#0a0f1e', stroke: C.line, 'stroke-width': 3 }),
    h('path', { d: rr(10, 10, 200, 420, 28), fill: 'url(#scr)' }),
    h('path', { d: rr(84, 20, 52, 9, 4.5), fill: '#1c2642' }),
    at(110, 150, pop({ id: 's4-card' },
      h('path', { d: rr(-92, -80, 184, 160, 18), fill: '#151d36', stroke: C.amber, 'stroke-opacity': 0.6 }),
      h('path', { d: rr(-74, -62, 96, 28, 14), fill: C.amber, 'fill-opacity': 0.18 }),
      text(-26, -42, '高危操作', { 'text-anchor': 'middle', 'font-size': 15, 'font-weight': 700, fill: C.amber }),
      text(-74, 4, 'agent 请求', { 'font-size': 16, fill: C.dim }),
      text(-74, 40, '删除 3 个文件', { 'font-size': 24, 'font-weight': 700 }))),
    at(110, 322, h('g', { id: 's4-fp' }, fp,
      h('path', { id: 's4-scan', d: ring(42), fill: 'none', stroke: C.cyan, 'stroke-width': 4, 'stroke-linecap': 'round' })),
    pop({ id: 's4-ok' },
      h('circle', { r: 42, fill: C.mint, 'fill-opacity': 0.14, stroke: C.mint, 'stroke-width': 3 }),
      check(C.mint, 6, 2))),
    text(110, 404, '指纹签名确认', { id: 's4-l1', 'text-anchor': 'middle', 'font-size': 18, fill: C.dim }),
    text(110, 404, '已签名', { id: 's4-l2', 'text-anchor': 'middle', 'font-size': 18, 'font-weight': 700, fill: C.mint }),
  ));
  const files = [0, 1, 2].map((i) => at(85 + i * 100, 100, pop({ id: `s4-f${i}` },
    h('path', { id: `s4-fr${i}`, d: rr(-24, -30, 48, 60, 6), fill: '#16213d', stroke: C.violet, 'stroke-width': 2 }),
    h('path', { d: 'M -12 -12 H 12 M -12 -2 H 12 M -12 8 H 4', stroke: '#3a4775', 'stroke-width': 3, 'stroke-linecap': 'round' }),
    text(0, 52, `old_${i + 1}.log`, { class: 'mono', 'font-size': 13, fill: C.dim, 'text-anchor': 'middle' }))));
  const laptop = at(510, 160, pop({ id: 's4-mac' },
    h('path', { d: rr(0, 0, 370, 240, 14), fill: '#0a0f1e', stroke: C.line, 'stroke-width': 3 }),
    h('path', { d: rr(10, 10, 350, 220, 8), fill: 'url(#scr)' }),
    h('path', { d: 'M -28 252 H 398 L 380 272 H -10 Z', fill: '#141c33', stroke: C.line, 'stroke-width': 2 }),
    files,
    at(185, 118, pop({ id: 's4-done' },
      h('circle', { r: 34, fill: C.mint, 'fill-opacity': 0.14, stroke: C.mint, 'stroke-width': 3 }),
      check(C.mint, 5, 1.6),
      text(0, 64, '已执行', { 'text-anchor': 'middle', 'font-size': 20, 'font-weight': 700, fill: C.mint }))),
    h('path', { id: 's4-cur', d: 'M 0 0 L 0 26 L 7 19 L 12 30 L 17 28 L 12 17 L 22 17 Z', fill: '#fff', stroke: '#05070d', 'stroke-width': 1.5 }),
  ));
  const relay = at(382, 330, pop({ id: 's4-relay' },
    h('circle', { r: 42, fill: '#0e1630', stroke: C.cyan, 'stroke-width': 2 }),
    h('path', { d: 'M -16 -7 H 14 M 8 -13 L 14 -7 L 8 -1 M 16 8 H -14 M -8 2 L -14 8 L -8 14', fill: 'none', stroke: C.cyan, 'stroke-width': 3.5, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }),
    text(0, 74, '设备中继', { 'text-anchor': 'middle', 'font-size': 18, fill: C.dim })));
  add(v,
    h('path', { id: 's4-w1', d: 'M 252 330 H 340', fill: 'none', stroke: '#3a4775', 'stroke-width': 2.5 }),
    h('path', { id: 's4-w2', d: 'M 424 330 C 462 330 470 280 508 280', fill: 'none', stroke: '#3a4775', 'stroke-width': 2.5 }),
    text(470, 300, 'wss', { id: 's4-wss', class: 'mono', 'font-size': 14, fill: C.dim }),
    h('path', { id: 's4-req', d: 'M 508 280 C 470 280 462 330 382 330 L 252 330', fill: 'none' }),
    phone, laptop, relay,
    h('circle', { id: 's4-pq', r: 8, fill: C.amber, filter: 'url(#glow)' }),
    h('circle', { id: 's4-ps', r: 8, fill: C.mint, filter: 'url(#glow)' }),
  );
}

function draw4(t, u) {
  const kp = ease.outExpo(prog(u, 0, 0.6));
  pose($('#s4-phone'), { o: prog(u, 0, 0.25), y: (1 - kp) * 70 });
  const km = ease.outExpo(prog(u, 0.1, 0.7));
  pose($('#s4-mac'), { o: prog(u, 0.1, 0.35), y: (1 - km) * 70 });
  popIn($('#s4-relay'), u, 0.2, 0.4, 0.5);
  drawStroke($('#s4-w1'), ease.outCubic(prog(u, 0.35, 0.65)));
  drawStroke($('#s4-w2'), ease.outCubic(prog(u, 0.45, 0.75)));
  $('#s4-wss').setAttribute('opacity', prog(u, 0.6, 0.8));

  // agent 在电脑上选中文件 → 请求经中继回到手机
  const kc = ease.inOutCubic(prog(u, 0.45, 0.95));
  const cur = $('#s4-cur');
  move(cur, lerp(300, 108, kc), lerp(196, 120, kc));
  cur.setAttribute('opacity', prog(u, 0.4, 0.5) * (1 - prog(u, 2.3, 2.45)));
  const sel = u >= 0.95;
  [0, 1, 2].forEach((i) => {
    $(`#s4-fr${i}`).setAttribute('stroke', sel ? C.amber : C.violet);
    const kf = ease.inCubic(prog(u, 2.3 + i * 0.07, 2.5 + i * 0.07));
    pose($(`#s4-f${i}`), { o: 1 - kf, s: 1 - 0.5 * kf });
  });
  const req = $('#s4-req');
  const kq = ease.inOutCubic(prog(u, 0.95, 1.3));
  const pq = pointAt(req, kq);
  const q = $('#s4-pq');
  q.setAttribute('cx', pq.x);
  q.setAttribute('cy', pq.y);
  q.setAttribute('opacity', span(u, 0.95, 1.0, 1.25, 1.32));

  popIn($('#s4-card'), u, 1.25, 0.35, 0.7);
  $('#s4-fp').setAttribute('opacity', prog(u, 1.35, 1.5) * (1 - prog(u, 2.0, 2.1)));
  drawStroke($('#s4-scan'), ease.inOutCubic(prog(u, 1.5, 2.0)));
  popIn($('#s4-ok'), u, 2.0, 0.3, 0.4);
  $('#s4-l1').setAttribute('opacity', prog(u, 1.35, 1.5) * (1 - prog(u, 1.95, 2.05)));
  $('#s4-l2').setAttribute('opacity', prog(u, 2.0, 2.1));

  const ks = ease.inOutCubic(prog(u, 2.05, 2.4));
  const ps = pointAt(req, 1 - ks);
  const s = $('#s4-ps');
  s.setAttribute('cx', ps.x);
  s.setAttribute('cy', ps.y);
  s.setAttribute('opacity', span(u, 2.05, 2.1, 2.35, 2.42));
  popIn($('#s4-done'), u, 2.45, 0.3, 0.4);
}

// ---------- 05 Rust 内核、三端原生 ----------

const CRATES = [
  ['proto', C.cyan], ['store', C.cyan], ['auth', C.cyan], ['gateway', C.cyan],
  ['control', C.cyan], ['orchestrator', C.cyan], ['notify', C.cyan], ['catalog', C.cyan],
  ['sandbox', C.cyan], ['keyvault', C.cyan], ['server', C.cyan], ['llm-gw', C.violet],
  ['relay', C.violet], ['agent-shim', C.violet], ['desktop', C.mint], ['client-core', C.mint],
];
const DEVICES = [
  { x: 150, name: 'iOS', sub: 'Swift · SwiftUI', kind: 'ios', color: C.cyan },
  { x: 400, name: 'Android', sub: 'Kotlin · Compose', kind: 'android', color: C.violet },
  { x: 680, name: 'macOS', sub: 'Swift · SwiftUI', kind: 'mac', color: C.mint },
];

function build5() {
  const v = $('#v5');
  const screenUi = (c, w) => [
    h('path', { d: rr(-w / 2, -50, w, 14, 7), fill: c, 'fill-opacity': 0.3 }),
    h('path', { d: rr(-w / 2, -26, w * 0.7, 14, 7), fill: '#1a2542' }),
    h('path', { d: rr(-w / 2, -2, w * 0.9, 30, 9), fill: '#1a2542' }),
  ];
  const devices = DEVICES.map((d, i) => at(d.x, 150, pop({ id: `s5-d${i}` },
    d.kind === 'mac'
      ? [
          h('path', { d: rr(-118, -82, 236, 150, 12), fill: C.panel, stroke: '#3a4775', 'stroke-width': 3 }),
          at(0, 8, screenUi(d.color, 170)),
          h('path', { d: 'M -140 74 H 140 L 126 90 H -126 Z', fill: '#141c33', stroke: '#3a4775', 'stroke-width': 2 }),
        ]
      : [
          h('path', { d: rr(-52, -100, 104, 200, 22), fill: C.panel, stroke: '#3a4775', 'stroke-width': 3 }),
          d.kind === 'ios'
            ? h('path', { d: rr(-18, -88, 36, 10, 5), fill: '#1c2642' })
            : h('circle', { cy: -83, r: 5, fill: '#1c2642' }),
          at(0, 8, screenUi(d.color, 72)),
        ],
    text(0, 134, d.name, { 'text-anchor': 'middle', 'font-size': 28, 'font-weight': 600 }),
    text(0, 160, d.sub, { 'text-anchor': 'middle', class: 'mono', 'font-size': 14, fill: C.dim }))));
  const wires = h('g', { id: 's5-w' }, DEVICES.map((d, i) => [
    h('line', { x1: d.x, y1: 324, x2: d.x, y2: 384, stroke: '#3a4775', 'stroke-width': 2 }),
    h('circle', { id: `s5-p${i}`, cx: d.x, cy: 324, r: 4.5, fill: d.color }),
  ]));
  const core = pop({ id: 's5-core' },
    h('path', { d: rr(60, 384, 780, 80, 24), fill: '#10172e', stroke: 'url(#gCV)', 'stroke-width': 2.5 }),
    h('path', { d: rr(92, 404, 96, 40, 20), fill: C.amber }),
    text(140, 431, 'Rust', { 'text-anchor': 'middle', 'font-size': 22, 'font-weight': 800, fill: '#1a0f00' }),
    text(210, 434, 'client-core', { class: 'mono', 'font-size': 28 }),
    text(808, 432, '三端共享 · UniFFI', { 'text-anchor': 'end', 'font-size': 20, fill: C.dim }));
  const chips = CRATES.map(([name, color], i) => {
    const col = i % 4, row = Math.floor(i / 4);
    return at(60 + col * 200 + 90, 534 + row * 62 + 24, pop({ id: `s5-c${i}` },
      h('path', { id: `s5-cr${i}`, d: rr(-90, -24, 180, 48, 12), fill: C.panel, stroke: color, 'stroke-width': 2 }),
      text(0, 7, name, { class: 'mono', 'font-size': 19, 'text-anchor': 'middle' })));
  });
  add(v,
    devices, wires, core,
    text(60, 516, '16 个 crate · 一个 cargo workspace', { id: 's5-gl', 'font-size': 18, fill: C.dim }),
    chips,
  );
}

function draw5(t, u) {
  DEVICES.forEach((d, i) => {
    popIn($(`#s5-d${i}`), u, i * 0.1, 0.5, 0.6);
    const ph = (u * 1.4 + i * 0.33) % 1;
    const p = $(`#s5-p${i}`);
    p.setAttribute('cy', 324 + 60 * ph);
    p.setAttribute('opacity', Math.sin(ph * Math.PI) * prog(u, 0.6, 0.8));
  });
  $('#s5-w').setAttribute('opacity', prog(u, 0.35, 0.6));
  const kc = ease.outExpo(prog(u, 0.45, 0.9));
  pose($('#s5-core'), { o: prog(u, 0.45, 0.6), y: (1 - kc) * 30 });
  $('#s5-gl').setAttribute('opacity', prog(u, 0.7, 0.9));
  CRATES.forEach((_, i) => {
    const st = 0.75 + i * 0.05;
    popIn($(`#s5-c${i}`), u, st, 0.35, 0.7);
    const hl = span(u, st + 0.1, st + 0.25, st + 0.5, st + 0.9);
    $(`#s5-cr${i}`).setAttribute('stroke-opacity', 0.35 + 0.65 * hl);
    $(`#s5-cr${i}`).setAttribute('fill-opacity', 1 - 0.3 * hl);
  });
}

// ---------- 06 品牌落版 ----------

function draw6(t, u) {
  $$('#wave i').forEach((w, j) => {
    const k = prog(u, j * 0.14, 1.3 + j * 0.14);
    const r = 80 + 1000 * ease.outCubic(k);
    Object.assign(w.style, { width: `${2 * r}px`, height: `${2 * r}px`, left: `${-r}px`, top: `${-r}px` });
    w.style.opacity = String((1 - k) * 0.7);
  });
  const km = ease.outBack(prog(u, 0, 0.6));
  pose($('#logo-mark'), { o: prog(u, 0, 0.2), s: 0.6 + 0.4 * km, r: (1 - km) * -14 });
  const shell = $('#lm-shell');
  drawStroke(shell, ease.inOutCubic(prog(u, 0, 0.7)));
  shell.setAttribute('fill-opacity', prog(u, 0.25, 0.7));
  popIn($('#lm-t'), u, 0.3, 0.4, 0.4);
  popIn($('#lm-dot'), u, 0.65, 0.3, 0);
  const ph = u > 0.95 ? ((u - 0.95) % 1.2) / 1.2 : 0;
  const ping = $('#lm-ping');
  ping.setAttribute('r', 12 + 16 * ease.outCubic(ph));
  ping.setAttribute('opacity', u > 0.95 ? 1 - ph : 0);

  revealChars($('#wordmark'), t, 16.3, { stagger: 0.045, rise: 60, dur: 0.7 });
  revealChars($('#tg-a'), t, 16.95, { stagger: 0.04, rise: 30 });
  revealChars($('#tg-b'), t, 17.35, { stagger: 0.06, rise: 30 });
  const ks = ease.outCubic(prog(u, 1.7, 2.3));
  pose($('#slogan'), { o: ks, y: (1 - ks) * 16, blur: (1 - ks) * 4 });
  pose($('#logo'), { s: 1 + 0.025 * ease.outCubic(prog(u, 0, 4)) });
}

// ---------- 全局层 ----------

const CUES = [3.5, 6.5, 10, 13];

window.drawGlobal = (t) => {
  const L = ease.inOutCubic(prog(t, 15.6, 16.8));
  const blobs = $$('.blob');
  const pos = [
    [1450 + 120 * Math.sin(t * 0.35), 330 + 90 * Math.cos(t * 0.28), 760, 470],
    [1150 + 160 * Math.cos(t * 0.3), 760 + 80 * Math.sin(t * 0.4), 1160, 600],
    [380 + 100 * Math.sin(t * 0.25), 820 + 60 * Math.cos(t * 0.33), 960, 560],
  ];
  blobs.forEach((b, i) => {
    const [x, y, cx, cy] = pos[i];
    b.style.transform = `translate(${lerp(x, cx, L)}px, ${lerp(y, cy, L)}px) scale(${1 + 0.25 * L})`;
  });
  $('#grid').style.backgroundPosition = `${-t * 8}px ${-t * 4}px`;
  $('#grid').style.opacity = String(1 - 0.6 * L);

  const chrome = prog(t, 0.3, 0.8) * (1 - prog(t, 15.6, 15.9));
  pose($('#brand'), { o: chrome, x: (1 - ease.outExpo(prog(t, 0.3, 0.9))) * -20 });
  pose($('#progress'), { o: chrome });
  $$('#progress b').forEach((b, i) => (b.style.width = `${prog(t, CUT[i], CUT[i + 1]) * 100}%`));

  let sweep = 0, flash = 0, sx = -260;
  for (const c of CUES) {
    const k = prog(t, c - 0.16, c + 0.24);
    if (k > 0 && k < 1) {
      sweep = Math.sin(k * Math.PI);
      sx = -260 + 2440 * ease.inOutCubic(k);
    }
    if (t >= c) flash = Math.max(flash, 0.16 * (1 - prog(t, c, c + 0.3)));
  }
  if (t >= 16) flash = Math.max(flash, 0.6 * (1 - ease.outCubic(prog(t, 16, 16.7))));
  const sw = $('#sweep');
  sw.style.transform = `translateX(${sx}px)`;
  sw.style.opacity = String(sweep);
  $('#flash').style.opacity = String(flash);
  $('#fade').style.opacity = String(Math.max(1 - prog(t, 0, 0.35), ease.inCubic(prog(t, 19.3, 20))));
};

// ---------- 组装 ----------

(function grain() {
  const c = document.createElement('canvas');
  c.width = c.height = 256;
  const ctx = c.getContext('2d');
  const img = ctx.createImageData(256, 256);
  const r = rand(42);
  for (let i = 0; i < 256 * 256; i++) {
    const v = Math.floor(r() * 256);
    img.data.set([v, v, v, 255], i * 4);
  }
  ctx.putImageData(img, 0, 0);
  $('#grain').style.backgroundImage = `url(${c.toDataURL()})`;
})();

build1();
build2();
build3();
build4();
build5();

const DRAW = [draw1, draw2, draw3, draw4, draw5];
DRAW.forEach((draw, i) => {
  const s = CUT[i], e = CUT[i + 1];
  const sec = document.querySelector(`[data-scene="${i}"]`);
  const vis = $('.vis', sec);
  scene(s, e, (t, u) => {
    drawCopy(sec, t, s, e);
    draw(t, u);
    exitVis(vis, t, e);
  });
});
scene(16, 20.01, draw6);
