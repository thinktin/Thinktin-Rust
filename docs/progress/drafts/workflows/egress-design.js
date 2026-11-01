export const meta = {
  name: 'egress-design',
  description: 'Design the controlled internet egress for agent sandboxes (WBS 2.7): survey, 3 designs, 2 judges, synthesis, critic',
  phases: [
    { title: 'Survey', detail: 'our network today, egress proxy options, what agents and tools need' },
    { title: 'Design', detail: 'three independent designs' },
    { title: 'Judge', detail: 'security judge and build/ops/cost judge' },
    { title: 'Synthesize', detail: 'one design document' },
    { title: 'Critique', detail: 'critic checks and fixes the document in place' },
  ],
}

const SP = '/tmp/claude-0/-home-user-Thinktin-Rust/6eda0341-41b9-5be1-b26f-1c110a526552/scratchpad'
const CONTEXT = `
Product: Thinktin (repo /home/user/Thinktin-Rust, branch claude/determined-lovelace-vn0j5h). This is READ-ONLY for you: do not edit repo files, commit or push. You may write only the scratchpad file you are told to write.
- Users in mainland China adopt AI agents (Claude Code, Codex, Hermes, OpenClaw, Pi; manifests in crates/catalog/manifests) that run in cloud sandboxes, one per agent instance, and command them from a phone app.
- Deployment: Alibaba Cloud domestic account, Tokyo region. Agent sandboxes are ACS containers (docs/sandbox-acs.md, crates/sandbox/src/acs.rs, deploy/aliyun/*). There is also a Cube backend (docs/sandbox-cube.md) and a local backend.
- A service machine in the same VPC runs the gateway and the model gateway (crates/llm-gw, port 8790). Docs: docs/handoff.md, docs/deploy-aliyun-sg.md.
- Today sandboxes have NO internet: allow_internet_access=false, allowOut only the model gateway IP, no NAT.
- WBS 2.7 (egress gateway and network policy) is planned and not built. docs/threat-model.md lists the egress allowlist and blocking the metadata endpoint as the top pre-launch todo. docs/vault.md plans credential header injection by an egress proxy. docs/architecture-v3.md describes egress policy per template.
- Next consumer: a browser (Chromium) inside each sandbox. See docs/browser.md, written today. Its recommendation is a self-built in-sandbox browser whose traffic goes through this egress channel. Other consumers: package installs (npm/pip/apt/cargo), git, API calls the user asks the agent to make (with vault credentials), web fetch tools.
- Earlier research is in ${SP}/browser_research.json. Its "code" map has file:line facts about the network today.
- The founder is non-technical. They asked to design the "受管控的上网通道" (controlled internet channel) first, then the browser on top of it.
`

const MAP_SCHEMA = { type: 'object', properties: {
  summary: { type: 'string' },
  facts: { type: 'array', items: { type: 'object', properties: { claim: { type: 'string' }, source: { type: 'string', description: 'file:line or URL' } }, required: ['claim', 'source'] } },
  implications: { type: 'array', items: { type: 'string' } },
  unknowns: { type: 'array', items: { type: 'string' } },
}, required: ['summary', 'facts', 'implications', 'unknowns'] }

const SURVEYS = [
  { key: 'ours', prompt: `Survey OUR codebase and docs for everything the egress channel must fit. Cite file:line for every fact.
Cover:
1. How sandboxes are networked per backend: the ACS allowOut semantics, the Cube network policy and traffic tokens, local.
2. Sandbox identity: how sandboxes are identified and authenticated. Includes the sandbox token (THINKTIN_SANDBOX_TOKEN; issued in crates/auth/src/grants.rs sandbox_token, verified in llm-gw), instances.sandbox_address and pod IPs, and token_epoch revocation.
3. llm-gw: its SSRF guard (crates/llm-gw/src/ssrf.rs), its --egress-proxy option, and how it is deployed (deploy/k8s/overlays/tokyo, deploy/aliyun/network.py security groups).
4. The vault credential-injection plan (docs/vault.md) and the scrubber.
5. Plans in docs/architecture-v3.md, docs/threat-model.md and docs/wbs.md (2.7 and related): the per-template egress policy and the cost/anti-abuse table.
6. How agent-shim sets env for agents (crates/agent-shim/src/config.rs), e.g. HTTP(S)_PROXY, NO_PROXY, NODE_* and any offline flags.
7. What the agents need to reach today. See docs/agent-integration.md (offline mode, telemetry off).
8. Grants and scopes (GrantScope), PlanPolicy, approvals.
9. Where usage or audit could be recorded (store usage, audit_log, events).
10. Any existing tests about network blocking.` },
  { key: 'options', prompt: `Research, on the web with sources, the ways to build a controlled egress channel for untrusted agent sandboxes. Use WebSearch, with mode "extended" where facts are thin, and WebFetch on primary sources.
Cover:
(1) Open-source forward/egress proxies:
- Stripe Smokescreen (Go, MIT). Its CONNECT-only design, private-IP blocking, per-role ACLs via client identity, and maturity.
- Squid (GPL) with SSL-bump.
- Envoy (Apache-2.0) as a dynamic forward proxy with RBAC.
- tinyproxy.
- mitmproxy (for TLS interception).
- Rust building blocks: hyper/hyper-util CONNECT; hudsucker or similar for MITM; how hard a small Rust CONNECT proxy is.
- How AI-agent products do this, with sources. Examples: Anthropic sandbox-runtime / Claude Code's sandbox proxy and its domain allowlist, the OpenAI Codex cloud internet-access settings (domain allowlist presets), E2B, GitHub Copilot coding agent firewall, Daytona, Modal.
(2) Alibaba Cloud managed options and prices in Tokyo: NAT Gateway plus Cloud Firewall (云防火墙) NAT-boundary domain ACLs, ACS network policies, PrivateZone/DNS. Can they enforce per-sandbox domain policy, and what do they cost?
(3) Security best practice for SSRF-safe egress:
- DNS rebinding: resolve-then-pin.
- Blocking private, link-local and metadata ranges (100.100.100.200 on Alibaba Cloud), IPv6, IP-literal and decimal tricks.
- Ports.
- CONNECT to IPs.
- SNI vs Host mismatch.
- Bandwidth and rate limiting, abuse prevention: spam via SMTP, scanning, DDoS from our IP.
- Logging without content.
(4) TLS interception for credential injection: the risks, installing a CA in the sandbox, certificate pinning breakage, doing it only for opted-in domains.
(5) How common tools honour proxy env vars:
- Node.js 24 fetch/undici (NODE_USE_ENV_PROXY), npm, pnpm, yarn.
- Python requests/httpx/urllib, pip, uv.
- git, curl, Go, cargo, apt.
- Chromium --proxy-server.
- Bun and Deno.
Note what happens with tools that ignore the proxy when direct egress is blocked.
(6) Mainland China legal points relevant to operating an egress service for users:
- network log retention (网络安全法 Article 21, at least 6 months);
- real-name requirements;
- cross-border access concerns when a Tokyo egress serves mainland users (the MIIT 2017 notice);
- content obligations.
Give URLs for every fact. Say explicitly when unknown.` },
  { key: 'needs', prompt: `Research what each of our agents and their usual tools try to reach on the network, and what breaks when only an HTTP(S) proxy is available.
Use the manifests (crates/catalog/manifests/*.toml), agent-shim config rendering (crates/agent-shim/src/config.rs), docs/agent-integration.md, and the agents' official docs or repos on the web.
For each agent (Claude Code, Codex CLI, Hermes, OpenClaw, Pi), give:
- telemetry and update endpoints, and whether they are already disabled;
- plugin, skill or MCP downloads;
- web fetch / web search tools and which backend they call;
- whether it honours HTTPS_PROXY.
Then list the domains an "allowlist" preset would need for common developer work: npm, PyPI, crates.io, GitHub (including codeload, objects and raw), apt mirrors, Go proxy, Docker Hub, Hugging Face. Compare with presets other products publish (e.g. the OpenAI Codex cloud "common dependencies" allowlist, Claude Code sandbox defaults), with sources.
Also cover:
- git over SSH vs HTTPS;
- WebSocket over CONNECT;
- HTTP/3/QUIC (UDP) and whether blocking UDP is fine;
- DNS inside the sandbox when only a proxy exists: do tools need local DNS to resolve names before using a proxy?
Give file:line or URL for every fact.` },
]

phase('Survey')
const maps = (await parallel(SURVEYS.map(s => () =>
  agent(`${CONTEXT}\n\n${s.prompt}`, { label: `survey:${s.key}`, phase: 'Survey', schema: MAP_SCHEMA })
    .then(m => m ? ({ key: s.key, ...m }) : null)))).filter(Boolean)
log(`surveys done: ${maps.map(m => m.key).join(', ')}`)
const mapsText = JSON.stringify(maps, null, 1)

const DESIGN_OUT = `Produce a complete design as Markdown, in Chinese in the style of docs/*.md (code identifiers stay in English). Cover:
1. What it is for and the threat model (what an injected agent may try).
2. Architecture: where the proxy runs, how a sandbox reaches it (ACS allowOut, security group, Cube), and how the proxy knows which instance and which policy a request belongs to (auth). Also how revocation and stop-all cut access at once.
3. Policy model: modes (model-only / allowlist presets / open web with private ranges blocked), who sets them (template default, user per instance, plan/grant scope), and the default for launch. Cover ports, protocols, DNS handling, IP blocklists and anti-SSRF details.
4. TLS: CONNECT tunnel by default; if and how credential injection (vault) works; what is explicitly out of scope.
5. Limits and abuse: bandwidth, connections, bytes per day per user, and blocked ports such as SMTP. Plus logging (what is logged, retention, privacy) and metrics and alerts.
6. Agent side: env vars, NO_PROXY, the agent-shim local forwarder if any, tools that ignore proxies, and Chromium flags. Each of the five agents.
7. App/user side: what the user sees and controls (the switch, presets, a list of blocked attempts?), plus approvals.
8. Build vs adopt: your choice with reasons, licences, and ops (HA, scaling, cost per month at 10/100/1000 daily active users).
9. Phased plan: shippable phases with files touched, tests (including tests that prove metadata and private ranges are blocked on the real cluster), and person-days.
10. Decisions needing the founder, phrased in plain language, each with a recommended default.
Be concrete and grounded: cite file:line for existing code and URLs for external facts. Return ONLY the Markdown document.`

const ANGLES = [
  { key: 'A', name: 'Minimal and safe', brief: 'The smallest thing that is safe at launch: an explicit HTTP CONNECT proxy, ideally a small Rust service sharing llm-gw\'s SSRF code and sandbox-token auth, with no TLS interception, a few policy modes and strict blocklists. Optimise for low risk and low ops, and say what you deliberately leave out.' },
  { key: 'B', name: 'Adopt proven open source', brief: 'Prefer a proven open-source egress proxy (for example Stripe Smokescreen or Envoy) over writing our own. Integrate it with our auth, policy, logging and deployment, and compare honestly with writing a Rust one. Consider Alibaba Cloud managed pieces (NAT gateway, Cloud Firewall) if they help.' },
  { key: 'C', name: 'Full-featured for the roadmap', brief: 'Design for the roadmap: browser use, vault credential injection (selective TLS interception only for opted-in domains), per-plan and per-run policy from grants, user-visible blocked-request review and one-tap allow, per-user quotas, and a later mainland egress for Chinese sites. Keep launch scope shippable by phasing.' },
]

phase('Design')
const designs = (await parallel(ANGLES.map(a => () =>
  agent(`${CONTEXT}\n\nSurvey results (facts with sources):\n${mapsText}\n\nYour angle: **${a.name}**. ${a.brief}\nOther designers take other angles. Do the best complete design from yours.\n\n${DESIGN_OUT}`,
    { label: `design:${a.key}`, phase: 'Design' })
    .then(text => (text && text.length > 2000) ? ({ key: a.key, name: a.name, text }) : null)))).filter(Boolean)
log(`${designs.length} designs`)
if (designs.length === 0) return { error: 'no designs', maps }
const bundle = designs.map(d => `=== Design ${d.key} (${d.name}) ===\n${d.text}`).join('\n\n')

const JUDGE_SCHEMA = {
  type: 'object',
  properties: {
    scores: { type: 'array', items: { type: 'object', properties: {
      design: { type: 'string' }, score: { type: 'number' }, strengths: { type: 'array', items: { type: 'string' } },
      flaws: { type: 'array', items: { type: 'string' } } }, required: ['design', 'score', 'strengths', 'flaws'] } },
    best: { type: 'string' },
    graft: { type: 'array', items: { type: 'string' } },
    must_fix: { type: 'array', items: { type: 'string' }, description: 'errors any final design must avoid, with evidence' },
  },
  required: ['scores', 'best', 'graft', 'must_fix'],
}
const LENSES = [
  { key: 'security', text: 'Security: SSRF into our VPC (service machine, RDS, sandbox-manager, metadata 100.100.100.200), DNS rebinding, IP tricks, auth spoofing between sandboxes, revocation speed, TLS interception risks, abuse from our IP, logging privacy. Verify against the code and the sources.' },
  { key: 'build', text: 'Buildability, operations, cost and product fit: is the launch phase small and shippable, does it fit our deployment (ACS allowOut without wildcards, single service machine, security groups), do agents and tools actually work through it (proxy env support), how much ops it adds, and are the cost numbers right. Are the founder decisions sensible defaults? Verify against the code and the sources.' },
]
phase('Judge')
const judgments = (await parallel(LENSES.map(l => () =>
  agent(`${CONTEXT}\n\nYou are a judge. Lens: ${l.text}\nScore each design 0-10 under your lens, name the best, list ideas to graft from the others, and list must-fix errors with evidence.\n\n${bundle}`,
    { label: `judge:${l.key}`, phase: 'Judge', schema: JUDGE_SCHEMA })
    .then(j => (j && j.scores) ? ({ lens: l.key, ...j }) : null)))).filter(Boolean)
const tally = {}
for (const j of judgments) for (const s of j.scores) tally[s.design] = (tally[s.design] || 0) + s.score
const ranked = Object.entries(tally).sort((a, b) => b[1] - a[1])
log(`scores: ${ranked.map(([k, v]) => `${k}=${v}`).join(', ')}`)
const winner = ranked.length ? ranked[0][0] : designs[0].key

phase('Synthesize')
const draftPath = `${SP}/egress-draft.md`
const synth = await agent(`${CONTEXT}\n\nYou are the synthesizer. Base the final design on Design ${winner} (highest total), graft the listed ideas, and fix every must_fix item. Where judges disagree, decide and say why in one line. Produce ONE coherent design with the same 10 sections, concrete and phased, with a small, safe first phase. It must be ready to become docs/egress.md, with a short plain-language summary for the founder at the top.\n\nWrite it to ${draftPath}. Return a summary of the key decisions (max 40 lines).\n\nJudgments:\n${JSON.stringify(judgments, null, 1)}\n\n${bundle}`,
  { label: 'synthesize', phase: 'Synthesize' })

phase('Critique')
const critic = await agent(`${CONTEXT}\n\nYou are a strict critic and editor. Read ${draftPath}. Check it against every implication, unknown and pitfall in these survey results, and check every claim about our code (file:line) and every external fact (URL). Look especially for:
- SSRF holes: our VPC CIDRs, the metadata address, IPv6, DNS rebinding;
- auth spoofing between sandboxes;
- revocation gaps;
- agents or tools that will not work through it;
- cost or ops errors;
- missing tests.
Fix the document IN PLACE for every confirmed problem. If a claim cannot be verified, mark it as unverified rather than delete it. Append a section "评审记录" that lists what you changed and what you left open. Return a summary of the changes (max 30 lines).\n\nSurveys:\n${mapsText}`,
  { label: 'critic', phase: 'Critique' })

return { ranked, winner, judgments, synth, critic, draftPath }
