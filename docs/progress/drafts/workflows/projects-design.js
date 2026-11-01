export const meta = {
  name: 'projects-design',
  description: 'Design cross-user projects (8.13-8.19): 3 independent designs, judge panel, synthesis, completeness critic',
  phases: [
    { title: 'Design', detail: 'three independent implementation designs from different angles' },
    { title: 'Judge', detail: 'three judges score all designs (security, implementability, fidelity)' },
    { title: 'Synthesize', detail: 'merge the winner with the best ideas of the others into one design doc draft' },
    { title: 'Critique', detail: 'check the draft against every survey pitfall and open question' },
    { title: 'Revise', detail: 'close the gaps the critic found' },
  ],
}

const SP = '/tmp/claude-0/-home-user-Thinktin-Rust/6eda0341-41b9-5be1-b26f-1c110a526552/scratchpad'
const CONTEXT = `
You are designing the IMPLEMENTATION of "projects and cross-user collaboration" (WBS 8.13-8.19) for the Thinktin Rust backend in /home/user/Thinktin-Rust (branch claude/determined-lovelace-vn0j5h; do not commit, do not push, do not edit repo files).

Read first:
- docs/projects.md: the product design. Section 1 holds the user's decisions, and they are fixed. Take the section 11 defaults as accepted: auto-run within budget plus an owner notification, at most 10 users and 30 agents per project, no transfer, no template sharing.
- ${SP}/projects_survey.json: a code survey with six maps (teams, rls, visibility, keys, sessions, money). Each map has file:line facts, extension_points, pitfalls and open_questions. Line numbers can drift slightly; verify anything you rely on against the code.
- docs/architecture-v3.md section 4.11: same-user agent communication, already built (8.9-8.12: agents_list/agent_status, board, ask, urgent messages).
- The code itself under crates/ (store, orchestrator, gateway, auth, keyvault, llm-gw, control, agent-shim, client-core, proto).

Hard constraints:
- There is no production data. However, already-installed iOS and Android test builds call /v1/teams* and /v1/team-templates* through the client-core FFI (Team*, TeamTemplate* records). This container cannot build the iOS or Android UI; it can only regenerate the Android Kotlin binding. So the existing team API and FFI must keep working, for example as a compatibility view over single-user projects, until the apps switch (12.25/13.18). New project APIs and FFI are added alongside.
- Today isolation is per user: Postgres RLS on thinktin_app via app_user_id(), composite (x_id, user_id) foreign keys, and per-user DEKs. Worker roles (thinktin_worker) bypass RLS, so worker-side code must check membership explicitly. The production migration owner (thinktin_owner) is NOT a superuser and does not bypass FORCE RLS, but tests run as a superuser (see the rls map pitfalls).
- Each phase must compile, pass cargo test --workspace (integration tests use Postgres) and clippy, and leave the system working, so phases can ship one at a time. The next migration number is 0031.
- Follow repo idioms: Chinese doc comments and docs, existing Tx<Tenant>/Tx<Worker> patterns, ApiError mapping, str_enum in proto, #[uniffi(default)] for added FFI fields.
`

const ANGLES = [
  { key: 'A', name: 'DB-enforced boundary', brief: 'Put the project boundary in the database. Consider a project-scoped transaction, for example Db::project(user, project) setting app.project_id, possibly under a separate member role, so member reads never widen the existing tenant role. Use SECURITY DEFINER membership helpers that work under the non-superuser production owner, write-safe WITH CHECKs, and FKs or triggers replacing the same-user composite FKs. Explain how private-run tools are kept from seeing project data and project-run tools from seeing private data.' },
  { key: 'B', name: 'Ownership follows the agent, minimal schema change', brief: 'Keep runs, grants, approvals and usage owned by the agent\'s owner, so key, approvals, vault, computer, locale and billing follow automatically. Serve member-visible data through dedicated project endpoints and store functions with explicit project filters and safe projections, rather than widening RLS on existing tables. Minimise churn in existing code paths. Be explicit about where explicit checks replace RLS, and how you make that safe and testable.' },
  { key: 'C', name: 'Project-owned content and crypto-shredding', brief: 'Make the project the owner of everything shared: a project key (KMS-wrapped DEK) created eagerly, a project board and project artifacts sealed with it, and a clear story for run prompts, summaries and events (encrypt, copy into project tables, or delete) so that deleting a project really makes its content unreadable and an erased member\'s contributions stay. Also cover sessions and workspace per (instance, project) in the sandbox and their cleanup.' },
]

const DESIGN_OUT = `Produce a complete implementation design as Markdown (in Chinese, matching docs/*.md style; code identifiers stay in English). It must cover:
1. Data model and migration 0031+ (exact tables, columns, indexes, FKs, policies, grants). Say how teams and team templates map to projects and how the team API and FFI stay compatible.
2. The member read path and the data boundary (RLS and/or explicit checks), with the exact policy or function SQL for the risky parts.
3. Run ownership across users: run trees, parent FK, grants (scope = project ∩ owner authorization, owner revocation), budgets per owner (where enforced: llm-gw and/or executor), approvals, vault/computer per project, interrupts and stop-all.
4. Project keys and encryption, project board, project artifacts, deletion and account erasure.
5. Sessions and workspace per (instance, project) in the sandbox (agent-shim, exec, tools, handoff), cleanup on leave or delete.
6. Collaboration tools in project context: agents_list/agent_status/ask/board/delegate/pipelines. Who can see whom; the wait-cycle lock across users.
7. Invites and join (phone/link, rate limits, block), notifications and the project event feed (cursor), and what the FFI/API surface looks like.
8. Phasing: an ordered list of shippable phases (each with scope, files touched, tests, risk). Put the riskiest boundary work early with tests.
9. Decisions you made on each survey open_question (brief), and anything that genuinely needs the user (non-technical product choices only).
Be concrete (table and column names, function signatures, SQL) and grounded in the actual code; cite file:line for claims about existing behaviour. Return ONLY the Markdown document.`

phase('Design')
const designs = await parallel(ANGLES.map(a => () =>
  agent(`${CONTEXT}\n\nYour angle: **${a.name}**. ${a.brief}\nOther designers take other angles; do the best complete design from yours (you may adopt ideas from other angles where clearly better, but say why).\n\n${DESIGN_OUT}`,
    { label: `design:${a.key}`, phase: 'Design' })
    .then(text => ({ key: a.key, name: a.name, text }))))
const ok = designs.filter(d => d && d.text && d.text.length > 2000)
log(`${ok.length} designs produced`)
if (ok.length === 0) return { error: 'no designs' }

const bundle = ok.map(d => `=== Design ${d.key} (${d.name}) ===\n${d.text}`).join('\n\n')
const JUDGE_SCHEMA = {
  type: 'object',
  properties: {
    scores: { type: 'array', items: { type: 'object', properties: {
      design: { type: 'string' }, score: { type: 'number' }, strengths: { type: 'array', items: { type: 'string' } },
      flaws: { type: 'array', items: { type: 'string' } } }, required: ['design', 'score', 'strengths', 'flaws'] } },
    best: { type: 'string' },
    graft: { type: 'array', items: { type: 'string' }, description: 'specific ideas from non-best designs that the final design must adopt, each with its design letter' },
    must_fix: { type: 'array', items: { type: 'string' }, description: 'errors or gaps any final design must avoid, with evidence (file:line)' },
  },
  required: ['scores', 'best', 'graft', 'must_fix'],
}
const LENSES = [
  { key: 'security', text: 'Security and isolation: cross-user leakage (private runs, instances, users, vault, computer, artifacts), write paths, worker-side bypasses, RLS correctness under the non-superuser production owner, revocation and "invisible the instant they leave", prompt injection across users. Verify claims against the code.' },
  { key: 'build', text: 'Implementability and risk: is each phase shippable and testable on its own, how much existing code it churns, compatibility with the installed apps (team API/FFI), migration safety, performance (per-row policy cost, hot paths such as append_event and claim), and whether the cited code facts are true. Verify against the code.' },
  { key: 'product', text: 'Product fidelity and simplicity: does it implement docs/projects.md sections 1-10 faithfully (who commands, owner keys and budgets, approvals to owners, computer and vault off by default, sessions isolation, leave and delete semantics, notifications to the right people), without needless complexity? Are the user-facing decisions sensible defaults?' },
]
phase('Judge')
const judgments = (await parallel(LENSES.map(l => () =>
  agent(`${CONTEXT}\n\nYou are a judge. Lens: ${l.text}\nScore each design 0-10 under your lens, name the best, list ideas to graft from the others, and list must-fix errors with evidence.\n\n${bundle}`,
    { label: `judge:${l.key}`, phase: 'Judge', schema: JUDGE_SCHEMA })
    .then(j => j && j.scores ? ({ lens: l.key, ...j }) : null)))).filter(Boolean)

const tally = {}
for (const j of judgments) for (const s of j.scores) tally[s.design] = (tally[s.design] || 0) + s.score
const ranked = Object.entries(tally).sort((a, b) => b[1] - a[1])
log(`scores: ${ranked.map(([k, v]) => `${k}=${v}`).join(', ')}`)
const winner = (ranked[0] || [ok[0].key])[0]

phase('Synthesize')
const draftPath = `${SP}/projects-impl-draft.md`
const synth = await agent(`${CONTEXT}\n\nYou are the synthesizer. Base the final design on Design ${winner} (highest total score), graft the listed ideas from the others, and fix every must_fix item. Where judges disagree, decide and say why in one line. The result must be ONE coherent design (no "option A/B" left open), with the same 9 sections as the inputs, concrete SQL and signatures, and a phase plan whose first phase is small and safe.\n\nWrite the final document to ${draftPath} (create it; Chinese, docs style). Return a short summary of key decisions (max 40 lines).\n\nJudgments:\n${JSON.stringify(judgments, null, 1)}\n\n${bundle}`,
  { label: 'synthesize', phase: 'Synthesize' })

phase('Critique')
const CRIT_SCHEMA = {
  type: 'object',
  properties: {
    gaps: { type: 'array', items: { type: 'object', properties: {
      item: { type: 'string', description: 'the survey pitfall/open question or design section' },
      problem: { type: 'string' }, fix: { type: 'string' }, severity: { type: 'string' } }, required: ['item', 'problem', 'fix', 'severity'] } },
    wrong_facts: { type: 'array', items: { type: 'string' } },
  },
  required: ['gaps', 'wrong_facts'],
}
const crit = await agent(`${CONTEXT}\n\nYou are a completeness critic. Read ${draftPath}. Check it against EVERY pitfall and open_question in ${SP}/projects_survey.json (all six maps) and against docs/projects.md sections 1-10. Each one must be addressed, or deferred explicitly with a reason. Also verify the draft's claims about existing code (file:line) and its SQL (policies, FKs, functions) for correctness under PostgreSQL semantics and the non-superuser production owner. Report gaps (with concrete fixes) and wrong facts. Be strict; skip nothing.`,
  { label: 'critic', phase: 'Critique', schema: CRIT_SCHEMA })

phase('Revise')
const revised = await agent(`${CONTEXT}\n\nRevise ${draftPath} in place to close these gaps and correct these facts (verify each against the code first; if a gap is wrong, leave the doc and say so). Keep it one coherent design. Append a short section "评审记录" listing what the critic raised and what you did. Return a summary of the changes (max 30 lines).\n\n${JSON.stringify(crit, null, 1)}`,
  { label: 'revise', phase: 'Revise' })

return { ranked, winner, judgments, synth, crit, revised, draftPath }
