# 联网搜索默认可用：调研原始结果（2026-11-04）


## repo


# REPO FACTS: web search for the five agents, the gateway, and platform tools

Read-only survey of /home/user/Thinktin-Rust on branch `claude/determined-lovelace-vn0j5h` at commit `47e8ef6`. No files were changed and nothing was committed. Line numbers refer to that commit. Upstream facts are marked either "verified (URL, read 2026-11-04)" or "UNVERIFIED".

## Summary
- **No web tool is configured for any agent.** `crates/agent-shim/src/config.rs` never mentions WebSearch, WebFetch, `web_search` or `tools.web`, so every agent uses its upstream default. No search-service key exists anywhere in the repo: a grep for tavily, firecrawl, searxng, brave_api, serper, jina, bocha and similar finds only the comment at `crates/proto/src/egress.rs:20-22`.
- **llm-gw does not filter tools.** It forwards the request body unchanged apart from the model name, so vendor-side tools (Anthropic `web_search`/`web_fetch`, OpenAI Responses `web_search`, Chat-Completions search flags) go straight to the vendor. It also forwards the `anthropic-beta` and `openai-beta` headers. It records **only token counts**, so per-search fees are never recorded.
- **Platform MCP tools reach only Claude (both modes), Codex and Hermes.** Pi and OpenClaw do not get them (`per_session_mcp = false`). This matches what docs/browser.md says.
- **Search sites cannot be reached from sandboxes yet.** The egress proxy is built, but it has not been switched on in Tokyo, and the service machine has not been bought yet (`docs/egress.md:184-185`, `docs/progress/claude-determined-lovelace-vn0j5h.md:14`). ACS sandboxes are created with `allow_internet_access: false` and an `allowOut` list holding only the gateway IP (`crates/sandbox/src/acs.rs:372,376`; `deploy/k8s/overlays/tokyo/server.toml:37-41`).

## (1) The five agents: version, how their config is made, web tools

All configs are written by `config::render` (`crates/agent-shim/src/config.rs:114-156`), which dispatches on `[llm].config` in each manifest. Whenever an egress proxy is set, every agent gets the same proxy variables (`config.rs:421-457`).

### Claude
- **Pinned version:** claude-agent-acp 0.90.0, which bundles Claude Agent SDK 0.3.296 (`crates/catalog/manifests/claude.toml:10,46`). The CLI mode is Claude Code 2.1.296 (`docs/agent-integration.md:14`).
- **Config:** environment variables only, no files (`config.rs:163-187`; test at `config.rs:631-638`).
  - `ANTHROPIC_BASE_URL` = `{gw}/anthropic`, plus `ANTHROPIC_AUTH_TOKEN` and the model names.
  - `ANTHROPIC_DEFAULT_HAIKU_MODEL` = the `fast` alias (`:178`).
  - `DISABLE_AUTOUPDATER=1` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`.
  - The CLI mode passes `--permission-mode default` and `--mcp-config` (`crates/agent-shim/src/claude_cli.rs:89-112`).
- **Web tools: left at default.** No `allowedTools`, `disallowedTools`, settings.json or `skipWebFetchPreflight` anywhere. The shim classifies `WebFetch` and `WebSearch` as the `fetch` kind (`claude_cli.rs:586-597`, line 592).

### Codex
- **Pinned version:** codex-acp 2.2.2, which bundles @openai/codex 0.160.1 (`codex.toml:9,39`).
- **Config:** writes `.codex/config.toml` (`config.rs:189-219`).
  - Custom provider `thinktin` with `wire_api = "responses"` pointing at `{gw}/openai/v1`.
  - `features.plugins` and `features.apps` are false; analytics, feedback and otel are off.
  - The manifest sets `INITIAL_AGENT_MODE=read-only` (`codex.toml:24-26`).
- **Web tools: left at default.** Neither `web_search` nor `tools.web_search` is set. What Codex 0.160.1 does by default with a custom Responses provider is UNVERIFIED.

### Pi
- **Pinned version:** @earendil-works/pi-coding-agent 1.2.0 plus pi-acp 0.0.34 (`pi.toml:7,35`).
- **Config:** writes `.pi/agent/models.json` and `settings.json`, and sets `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1` and `PI_TELEMETRY=0` (`config.rs:245-271`).
- **Web tools:** none configured. No extensions are installed, and Pi has no permission system (`docs/agent-integration.md:136`). Whether Pi ships any web tool is UNVERIFIED.

### OpenClaw
- **Pinned version:** 2026.10.3 (`openclaw.toml:9,45`).
- **Config:** writes `.openclaw/openclaw.json` (`config.rs:276-343`).
  - `models.mode = "replace"` with provider `thinktin`.
  - `tools: {exec: {mode: "ask"}}` (`:327`).
  - `security.installPolicy` is on; update and telemetry are off; `OPENCLAW_CLAWHUB_URL=http://127.0.0.1:9`.
- **Web tools:** `tools.web.search` and `tools.web.fetch` are not set and no search-provider key is given. `docs/egress.md:12` says OpenClaw's web search depends on the chosen provider and that by default no service key is provided. Whether it can search with no key is UNVERIFIED.

### Hermes
- **Pinned version:** hermes-agent 0.19.0, installed as `hermes-agent[acp,mcp]==0.19.0` (`hermes.toml:7,34`).
- **Config:** writes `.hermes/config.yaml` (written as JSON) with provider `custom` and either `chat_completions` or `anthropic_messages` transport. It sets `skills.inline_shell=false`, `curator.enabled=false` and `HERMES_SKIP_NODE_BOOTSTRAP=1` (`config.rs:352-395`).
- **Web tools:** none configured. `docs/egress.md:13` says Hermes search and extract go through separate services that report themselves unavailable when missing. Hermes adds browser tools automatically if `/usr/bin/chromium` exists (`docs/browser.md:102-103`), but the image has no Chromium (`docs/browser.md:12`).

### Why Claude's built-in search would still show popups
- **The default policy pre-approves nothing.** `PlanPolicy::default()` has an empty `preauthorized_tools` (`crates/proto/src/domain.rs:389-394`). The executor passes it through (`crates/orchestrator/src/executor.rs:850`), and the shim is always started with `--on-unlisted ask` (`crates/orchestrator/src/exec.rs:125-131`).
- **So each WebSearch or WebFetch call asks the user.** Both tools are permission-gated upstream ("Permission required: Yes"; verified, https://code.claude.com/docs/en/tools-reference). Each call therefore becomes an `agent.permission_requested` event and an approval push.
- **WebSearch only works where the vendor runs it.** It is Anthropic's server-side search and is available only on the Claude API, Claude Platform on AWS, Foundry and some Vertex models (same page). Whether it works when routed through llm-gw to a non-Anthropic key is UNVERIFIED.
- **WebFetch adds a second popup.** Before every fetch it sends the hostname to `api.anthropic.com`, whatever the provider, unless `skipWebFetchPreflight: true` is set. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` does not turn this off (verified, https://code.claude.com/docs/en/data-usage). `api.anthropic.com` is in neither `SEARCH_HOSTS` nor `DEV_HOSTS` (`crates/proto/src/egress.rs:7-39`), so in `dev` mode the proxy would ask the user (`crates/proto/src/domain.rs:564-571`).

## (2) Does llm-gw pass vendor-side tools through?

### Routes
`/anthropic/v1/messages`, `/anthropic/v1/messages/count_tokens`, `/openai/v1/chat/completions` and `/openai/v1/responses`, plus model-list routes (`crates/llm-gw/src/proxy.rs:124-138`).

### Request body
- Only `model` is rewritten, `stream_options.include_usage` is added for Chat Completions where needed, and vault values are scrubbed. Every other field is forwarded byte-for-byte in its original order (`crates/llm-gw/src/body.rs:1-6`; `proxy.rs:723-773, 995-1006`; `docs/llm-gateway.md:66`).
- **The `tools` field is never inspected, so tool types are not filtered.** Anthropic `web_search_*`/`web_fetch_*`, Responses `{"type":"web_search"}` and vendor flags such as top-level search switches all pass through.
- The only things rejected:
  - duplicate or case-variant top-level keys;
  - more than 256 top-level keys;
  - non-standard spellings of model, stream, stream_options or background;
  - Responses requests with `background: true` (`proxy.rs:762-769`; `docs/llm-gateway.md:68-74`).

### Headers
- Anthropic flavour forwards `anthropic-version` (default `2023-06-01`), `anthropic-beta`, `accept` and `user-agent`. OpenAI flavour forwards `openai-beta`, `accept` and `user-agent` (`proxy.rs:535-562`).
- The `?beta=true` query is kept for Anthropic (`proxy.rs:990-993`).
- So any beta header a server tool needs reaches the vendor. Which tools need which beta headers is UNVERIFIED.

### Usage and billing
- The meter reads only `input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens` and `output_tokens` for Anthropic (`crates/llm-gw/src/usage.rs:186-200`), and prompt/completion or input/output tokens with cached details for OpenAI (`usage.rs:205-222`).
- The `Usage` struct holds only those four counters (`usage.rs:33-38`), and `UsageRecord` has no tool or search fields (`usage.rs:343-365`). A grep for `server_tool`, `web_search_requests` or `tool_use` in `crates/llm-gw/src` returns nothing.
- **So per-search fees are not recorded and do not count toward `daily_token_limit` or `charged_tokens`.** They land on the user's own vendor bill.
- The exact upstream usage field names (for example `usage.server_tool_use.web_search_requests`) are UNVERIFIED.

### Related notes in the repo
- `docs/egress.md:10` says searches run by the vendor do not pass through the sandbox proxy and would need a separate tool policy in the gateway. No such policy exists.
- `docs/progress/drafts/egress-survey.md:135` lists this as uncovered.

## (3) Which agents receive the platform MCP tools

The bridge is injected as a stdio MCP server named `thinktin` (`crates/agent-shim/src/bridge.rs:1-20,36`; entry built in `crates/agent-shim/src/main.rs:445-464`).

| Agent | `per_session_mcp` | Gets platform tools? |
|---|---|---|
| Claude (`acp` and `cli`) | true (`claude.toml:27,33`) | Yes. The CLI mode converts the list to `--mcp-config` (`claude_cli.rs:111-112,684-706`). |
| Codex | true (`codex.toml:27`) | Yes. Every MCP call needs approval in read-only mode (`docs/agent-integration.md:107`). |
| Hermes | true (`hermes.toml:22`) | Yes. Needs the `[mcp]` extra (`hermes.toml:1,32`). |
| Pi | false (`pi.toml:23`) | **No** |
| OpenClaw | false (`openclaw.toml:27`) | **No** |

- When `per_session_mcp` is false, the shim sends `mcpServers: []` (`crates/agent-shim/src/acp.rs:87-91`) and logs "ignores per-session MCP servers; they are not injected yet" (`crates/agent-shim/src/shim.rs:67-72`).
- `docs/agent-integration.md:109,152` confirms this: "Pi has no MCP; OpenClaw needs the bridge written into its config file." `docs/browser.md:81` says the same.
- The MCP `instructions` text, which includes the egress rules, therefore also reaches only Claude, Codex and Hermes (`bridge.rs:39-48`).

## (4) Adding a new platform tool

### Steps
1. **Implement the trait.** Implement `PlatformTools { fn tools(); async fn call(ctx, name, args) }` (`crates/orchestrator/src/shim.rs:97-102`). `ToolContext` carries user, instance, run, plan and grant (`shim.rs:64-72`). Export a name list such as `SCHEDULE_TOOLS` (`crates/orchestrator/src/tools.rs:27-32`).
2. **Register it.** Add it to the provider vec in `crates/server/src/workers.rs:141-157`, which feeds `ToolSet::new` (`workers.rs:167`). `ToolSet` dispatches by name (`tools.rs:413-437`).
3. **Grant it.**
   - Add the name to `default_platform_tools` (`crates/server/src/config.rs:123,136-148`). New grants get it through `default_scope` (`crates/gateway/src/routes/mod.rs:196-201`), which is used by instances.rs:52, plans.rs:185, runs.rs:80 and teams.rs:211.
   - Existing grants need a migration, following `crates/store/migrations/0026_ask.sql:15-21` (also 0024, 0025).
   - An empty scope means no platform tools (`crates/proto/src/domain.rs:410-411`).
4. **Executor filtering.**
   - The tool list sent to the agent is filtered by grant scope; delegate tools go only to the lead agent (`executor.rs:833-845`).
   - Calls are checked against `allowed_tools` (`executor.rs:1837-1866`).
   - Tools with side effects belong in `SIDE_EFFECT_TOOLS`, which makes repeated calls in one run return the earlier result (`executor.rs:276-284,1365-1400`).
5. **Run events.**
   - Every shim event is stored as `agent.<kind>`, including `agent.platform_tool_call` (`shim.rs:119-138`; `executor.rs:1260-1267`). Payloads are vault-scrubbed and size-bounded (`executor.rs:1210-1237`).
   - A tool can add its own events through `t.append_event`; see `plan.needs_confirmation` at `tools.rs:181-187`.
6. **Client.** The Apple app already sorts a tool named `web_search` into category `.other` (`apps/apple/ThinktinKit/Tests/ThinktinKitTests/ModelTests.swift:494`).

### Can a server-side platform tool call an external HTTP API?
- **Network: yes.**
  - The control plane runs on one ECS box with a public IP, under k3s. The doc says the services need public internet for model vendors, push and SMS (`docs/deploy-aliyun-sg.md:21-35`).
  - There is no NetworkPolicy; it is listed as not done (`docs/release.md:157`; `docs/deploy-checklist.md:133`).
  - The worker pod is an ordinary pod. Only llm-gw uses `hostNetwork` (`deploy/k8s/overlays/tokyo/kustomization.yaml:38-62`).
- **Existing outbound HTTP clients:**
  - IM bots: `crates/notify/src/im.rs:73-82` (https-only, no redirects, 3 s connect and 8 s total timeout, fixed base URLs, token removed from errors).
  - APNs, FCM and JPush: `crates/notify/src/apns.rs:70`, `fcm.rs:129`, `jpush.rs:76`.
  - S3/OSS: `crates/orchestrator/src/s3.rs:117`. The orchestrator crate already depends on reqwest (`crates/orchestrator/Cargo.toml:22`).
  - llm-gw's upstream client: `proxy.rs:100-122` (no redirects, https-only, a resolver that allows only public addresses, optional upstream proxy). `crates/llm-gw/src/ssrf.rs` can be reused.
- **No existing platform tool calls an external API.**
  - Vault tools use only the database and the outbox (`crates/orchestrator/src/vault.rs:1-30`, no reqwest).
  - IM and push messages are sent by separate dispatchers reading the outbox (`workers.rs:186-200`), not inside a tool call.
  - Egress approval reminders also go through the outbox (`crates/orchestrator/src/egress.rs:1-30`).
- **Design implications:**
  - A server-side search tool would run outside the sandbox egress proxy and its per-site approvals.
  - `proto::egress` deliberately excludes services that fetch arbitrary pages, such as Tavily `/extract` and r.jina.ai, for that reason (`crates/proto/src/egress.rs:20-22`). A server-side tool that only returns search results fits that rule; one that fetches pages would not.
  - Such a tool would reach only Claude, Codex and Hermes until Pi and OpenClaw get the bridge.

## (5) Model providers and protocols

The table is `crates/proto/src/vendors.rs:128-460`, last checked 2026-10-16 (`:16`), and documented at `docs/llm-gateway.md:241-262`. A = Anthropic Messages, C = Chat Completions, R = Responses.

| Vendor ids | Protocols |
|---|---|
| `deepseek` | A, C, R |
| `qwen-cn`, `qwen-intl`, `qwen-us`, `qwen-hk` (DashScope / Model Studio) | A, C, R |
| `glm-cn`, `glm-intl` (Zhipu / Z.ai; Responses uses a different prefix) | A, C, R |
| `kimi-cn`, `kimi-intl` | A, C, R |
| `minimax-cn`, `minimax-intl` | A, C, R |
| `anthropic` (its Chat endpoint is the OpenAI-compatibility layer) | A, C (no R) |
| `openai` | C, R |
| `gemini` (OpenAI-compatible endpoint) | C |
| `xai` | C, R |
| `mistral` | C |
| `doubao-cn` | A, C, R |
| `doubao-intl` (BytePlus) | C, R |
| `ernie` (Qianfan) | A, C |
| `hunyuan-cn`, `hunyuan-intl` (TokenHub) | A, C, R |
| `stepfun` | A, C |
| `custom` (user enters the endpoints; `proxy.rs:460-467`) | whichever endpoints the user supplies |

- That is 22 preset entries plus `custom`.
- There is no protocol translation. Codex needs R, so it cannot use Anthropic, Gemini, Mistral, Ernie or Stepfun keys (`docs/llm-gateway.md:264`).
- Which protocols each agent speaks:
  - Claude: A
  - Codex: R
  - Pi: C, A, R
  - OpenClaw: C, A, R
  - Hermes: C, A
  - (from the manifests' `[llm].protocols`)

## Unverified items
- Codex 0.160.1's default `web_search` setting, and what happens when its Responses `web_search` tool is sent to non-OpenAI vendors.
- Whether any vendor's Anthropic-compatible endpoint (DeepSeek, Qwen, GLM, Kimi and others) runs or accepts `web_search_*` server tools.
- Whether Pi has a built-in web tool; OpenClaw's keyless search fallback; Hermes's default search backend.
- The upstream usage field names for search-call counts and fees.



## agents

I checked how web search works in each of the five agents at the pinned versions. I read the packages themselves, not only their docs: the Claude Code binary, the Codex source at tag `rust-v0.160.1`, and the Pi, OpenClaw and Hermes packages. No repo files were changed and nothing was committed.

# How web search works in the five agents at the pinned versions

**Pinned versions** (crates/catalog/manifests/*.toml):
- **Claude:** claude-agent-acp 0.90.0, which contains Agent SDK 0.3.296 and the Claude Code CLI 2.1.296 (version string inside the binary) (claude.toml:10).
- **Codex:** codex-acp 2.2.2 with @openai/codex 0.160.1 (codex.toml:9).
- **Pi:** pi-coding-agent 1.2.0 with pi-acp 0.0.34 (pi.toml:7,35).
- **OpenClaw:** openclaw 2026.10.3 (openclaw.toml:9).
- **Hermes:** hermes-agent 0.19.0 (hermes.toml:7,34).

## Bottom line

1. **Search that runs at the model vendor** (Claude Code WebSearch, Codex `web_search`) is free for our servers. It is billed to the user's own vendor key. It only works if the vendor behind llm-gw supports the tool. Our gateway forwards the request body unchanged (crates/llm-gw/src/body.rs:1).
   - **Verified to work:** Anthropic, DeepSeek (both Anthropic and Responses formats), OpenAI (Responses), Qwen/DashScope (Responses).
   - **Not verified:** Kimi, GLM, MiniMax, Doubao, xAI, TokenHub.
2. **Search that runs inside the sandbox** (OpenClaw `web_search`, Hermes `web_search`) needs a search provider:
   - Out of the box with our config, **neither has a working search tool**.
   - Two key-free options reach hosts already in `SEARCH_HOSTS` (crates/proto/src/egress.rs:23-39) without a popup: OpenClaw's DuckDuckGo plugin (`html.duckduckgo.com`), and Brave's API (`api.search.brave.com`), which needs a key.
   - Hermes' key-free `ddgs` backend also queries engines that are **not** in `SEARCH_HOSTS`.
3. **Pi has no built-in web search.** Pi 1.2.0 does have native MCP, via `~/.pi/agent/mcp.json`. That contradicts docs/agent-integration.md:152, which says "Pi 本身没有 MCP".
4. **Claude Code WebFetch has a bug in our current config.** Every WebFetch first sends the hostname to `https://api.anthropic.com/api/web/domain_info?domain=…` from inside the sandbox.
   - `api.anthropic.com` is in neither `SEARCH_HOSTS` nor `DEV_HOSTS`, so our proxy would ask the user (or the fetch fails).
   - `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` (config.rs:186) does **not** turn this off. Only `skipWebFetchPreflight: true` in settings.json does, and config.rs writes no Claude settings.json at all.
5. **The one path that would cover all five agents:** a platform search tool served as MCP, with the key on the server side. Today it reaches Claude, Codex and Hermes through ACP `session/new`. Pi and OpenClaw would need it written into their own config files (pi.toml:23 and openclaw.toml:27 have `per_session_mcp = false`).

## Per-agent table

| Agent (pinned) | Built-in search? | Where it runs | Key / provider needed | Works behind our gateway with a non-Anthropic/OpenAI model? | Config knobs |
|---|---|---|---|---|---|
| **Claude Code** 2.1.296 (inside SDK 0.3.296) | Yes: `WebSearch` (Anthropic server tool `web_search_20250305`, `max_uses: 8`) and `WebFetch` (fetched in the sandbox) | WebSearch: a second Messages request to `ANTHROPIC_BASE_URL` (our gateway), executed by the vendor. WebFetch: sandbox → egress proxy → target site, then a separate model call to summarize | The vendor must implement the server tool. Billed to the user's key: Anthropic $10 per 1,000 searches plus tokens; DeepSeek $0.75 per 1,000 from 2026-11-01 | **DeepSeek: yes** (documented). **Anthropic: yes.** Kimi / GLM pay-as-you-go / Qwen / MiniMax: **unverified**. Community report: GLM does not support it (unverified). The tool stays enabled for any custom base URL, so an unsupporting vendor may error or answer without results (unverified) | Deny with `permissions.deny: ["WebSearch"]` or ACP `disallowedTools`; `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION`; `skipWebFetchPreflight`; `CLAUDE_CODE_DISABLE_WEB_FETCH`; `WebFetch(domain:…)` permission rules |
| **Codex** 0.160.1 | Yes: hosted Responses tool `{"type":"web_search","external_web_access":…}` | Executed by the vendor behind `/openai/v1/responses` | The vendor's Responses API must support `web_search`. OpenAI $10 per 1,000 calls plus content tokens; DeepSeek $0.75 per 1,000 | Sent by default for our custom provider. **DeepSeek, Qwen/DashScope: documented.** Kimi, GLM, MiniMax, Doubao, xAI: **unverified**. If a vendor rejects the tool type, every Codex turn may fail (unverified) | Top-level `web_search = "disabled" \| "cached" \| "indexed" \| "live"` (default `cached`; `live` under full access); `tools.web_search` (domains, location, context size); legacy `features.web_search_request` and `features.web_search_cached` |
| **Pi** 1.2.0 | **No.** Default tools are read, bash, edit, write | n/a | n/a | n/a. Only MCP or bash (`curl` to a search host) | `~/.pi/agent/mcp.json` (`mcpServers`; per-tool exposure `direct`, `deferred`, `codemode` or `hidden`); `--no-mcp` |
| **OpenClaw** 2026.10.3 | Yes: `web_search` (pluggable providers) plus `web_fetch` (always local) | Inside the sandbox (Gateway sidecar → provider API). OpenAI-native search only for provider `openai` with the official base URL, so not for us | Bundled in the package: Gemini, Grok, MiniMax (Token Plan key), Ollama. External official plugins (install required): Brave, DuckDuckGo (no key), Exa, Firecrawl, Kimi, Parallel (paid key, or a free MCP), Perplexity, SearXNG, Tavily. Key-free providers are **never auto-selected** | Independent of the chat model. Needs a provider plus its key in the sandbox, or DuckDuckGo / Parallel-free / SearXNG selected explicitly | `tools.web.search.{enabled, provider, maxResults, timeoutSeconds, cacheTtlMinutes}`; `plugins.entries.<p>.config.webSearch.{apiKey, baseUrl}`; env such as `BRAVE_API_KEY`, `TAVILY_API_KEY`, `EXA_API_KEY`, `FIRECRAWL_API_KEY`, `PARALLEL_API_KEY`, `PERPLEXITY_API_KEY`/`OPENROUTER_API_KEY`, `KIMI_API_KEY`/`MOONSHOT_API_KEY`, `GEMINI_API_KEY`, `XAI_API_KEY`, `SEARXNG_BASE_URL`; `tools.web.fetch.provider`; MCP via `mcp.servers` |
| **Hermes** 0.19.0 | Yes: `web_search` and `web_extract` (in the `hermes-acp` toolset), hidden when no backend is available | Inside the sandbox (Python → backend API) | Auto-detect order: Tavily `TAVILY_API_KEY`, Exa `EXA_API_KEY`, Parallel `PARALLEL_API_KEY`, Firecrawl `FIRECRAWL_API_KEY` or `FIRECRAWL_API_URL` (self-host) or the Nous tool gateway, SearXNG `SEARXNG_URL`, Brave `BRAVE_SEARCH_API_KEY`, `ddgs` (no key, if the package is importable), xai. Extract only works with Firecrawl, Tavily, Exa or Parallel | Independent of the chat model. Our template currently has none of these, so the tools are hidden. `ddgs` is not a dependency of hermes-agent; installing it gives key-free search only | `web.backend`, `web.search_backend`, `web.extract_backend` in config.yaml; the env keys above; MCP via `mcp_servers` in config.yaml and ACP session MCP (needs the `[mcp]` extra) |

## Details per agent

### Claude Code (inside the claude-agent-acp 0.90.0 binary)

**When WebSearch is enabled** (read from the minified code in the binary):
- `isEnabled()` returns true for provider `firstParty`. That is what `ANTHROPIC_BASE_URL` plus `ANTHROPIC_AUTH_TOKEN` gives us (config.rs:163-187).
- It returns false only for a Claude-apps-gateway sign-in or Bedrock, and is model-gated on Vertex.
- So with our gateway, **the tool is always offered**, whatever vendor is behind it.

**What a WebSearch call sends:**
- A second request to `mainLoopModel()`, with thinking disabled and the system prompt "You run a web search for another Claude model…".
- `tools: [{type:"web_search_20250305", name:"web_search", allowed_domains, blocked_domains, max_uses:8}]`.
- A feature flag can switch this to the small model. Feature flags are off under `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, so we get the main model.
- The tool prompt says "Web search is only available in the US". What that restriction means in practice is unverified.
- Docs say: "The search backend is not configurable. To search with a different provider, add an MCP server that exposes a search tool" (code.claude.com/docs/en/tools-reference). Per call it may "issue up to eight backend searches". There is a 200-search session cap in the CLI; in the SDK the cap is per turn.

**Behind a gateway** (code.claude.com/docs/en/feature-availability): "feature availability matches the underlying provider the gateway forwards to". Bedrock does not expose the server tool.

**WebFetch:**
- Runs in the sandbox and honors the proxy environment variables.
- Refuses hosts without a dot, follows only same-host redirects, and summarizes the page with a separate model call.
- Preflight: `api.anthropic.com/api/web/domain_info?domain=` is hard-coded and does not follow `ANTHROPIC_BASE_URL`. Docs: "runs regardless of which model provider you use and is not affected by `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` … set `skipWebFetchPreflight: true`" (code.claude.com/docs/en/data-usage).
- The ACP adapter reads `settingSources: ["user","project","local"]` (claude-agent-acp dist/acp-agent.js:7897). So `$CLAUDE_CONFIG_DIR/settings.json` would work.
- The WebFetch prompt says: "IMPORTANT: If an MCP-provided web fetch tool is available, prefer using that tool instead of this one".

**MCP preference:** the WebSearch prompt has **no** stated preference for MCP search. To force MCP search, deny `WebSearch`.

### Codex 0.160.1 (source at tag `rust-v0.160.1`, commit d27764b)

- `resolve_web_search_mode` (core/src/config/mod.rs:2683): an explicit `web_search` setting wins, then `features.web_search_cached` → Cached, then `features.web_search_request` → Live. With none of these set, the default is **Cached** (mod.rs:3769).
- Per turn (mod.rs:3085-3125): the full-access permission profile prefers Live. Our `INITIAL_AGENT_MODE=read-only` (codex.toml:26) therefore gets **Cached**, which sends `external_web_access:false`.
- The hosted tool is added unless the model metadata says "responses lite" or the provider capability `web_search` is false (core/src/tools/spec_plan.rs:621-651). Custom providers get `ProviderCapabilities::default()`, which sets `web_search: true` and `external_web_access: true` (model-provider/src/provider.rs:52-68, 461-473).
- Our alias model falls back to metadata with `use_responses_lite: false` (models-manager/src/model_info.rs:99-139). So **the tool is sent to every vendor**.
- Wire format: `#[serde(rename="web_search")]` (tools/src/tool_spec.rs:39-53).
- codex-acp 2.2.2 does not touch web search config; it only renders `webSearch` items.
- Docs: `features.network_proxy` and `permissions.*.network.domains` "do not restrict web search". Search runs at the vendor, so there is no popup and it never goes through our proxy (learn.chatgpt.com config reference).
- The docs also list `model_providers.<id>.capabilities.external_web_access` and `supports_standalone_web_search`. **Unverified** whether the `capabilities` key exists at 0.160.1; the source I read has only `supports_standalone_web_search`.

### Pi 1.2.0

- docs/cli.md:128: default tools are `read`, `bash`, `edit`, `write`.
- No `web_search` string anywhere in the bundle, in pi-ai 1.2.0 or in the docs.
- docs/mcp.md: native MCP over stdio or streamable HTTP, configured in `~/.pi/agent/mcp.json`. The path is resolved from `agentDir`, i.e. `PI_CODING_AGENT_DIR` (extensions/mcp/cli.js:328; config.js:491).
- Tools appear as `mcp__<server>__<tool>`. Default exposure is `codemode`; a search tool should get `direct` exposure so the model sees it.
- pi-acp 0.0.34 stores `mcpServers` but never forwards them to Pi (dist/index.js:847). Per-session injection really does not work; the config file does.
- **Unverified:** whether `PI_OFFLINE=1` (config.rs:248) affects MCP connections.

### OpenClaw 2026.10.3 (docs/tools/web.md and the bundled extensions)

- `web_search` is enabled by default, but auto-detect "only picks a provider that needs a credential when it finds one configured". DuckDuckGo, Parallel-free, Ollama and Codex "never win auto-detection" (web.md:241-276).
- Bundled search contracts (`dist/extensions/*/openclaw.plugin.json`): only `google` (gemini), `minimax`, `ollama` and `xai` (grok).
- Brave, DuckDuckGo, Exa, Firecrawl, Moonshot, Parallel, Perplexity, SearXNG and Tavily are separate npm packages (`@openclaw/<x>-plugin`; listed in dist/native-hook-relay/official-external-plugin-catalog). Our `security.installPolicy` (config.rs:329) blocks installs at runtime, so any plugin must be **pre-installed at template build**.
- `@openclaw/duckduckgo-plugin@2026.10.3` exists on npm. The 2026.10.10 build scrapes `https://html.duckduckgo.com/html` (in `SEARCH_HOSTS`). It is "experimental, unofficial … expect occasional breakage from bot-challenge pages".
- The Brave plugin calls `https://api.search.brave.com` (in `SEARCH_HOSTS`).
- Native OpenAI search applies only to "provider `openai`, no base URL or an official OpenAI API base URL", so it never applies to our `thinktin` provider (web.md:286-296).
- **Unverified:** whether OpenClaw's guarded fetch for search providers honors `HTTPS_PROXY`/`NODE_USE_ENV_PROXY` in our sandbox. It does local DNS and SSRF checks.

### Hermes 0.19.0 (tools/web_tools.py, plugins/web/*)

- Backend choice: `_get_backend()` (web_tools.py:223-271). The tools are gated by `check_web_api_key()` (web_tools.py:1050-1083).
- The `hermes-acp` toolset includes `web_search` and `web_extract` (toolsets.py:380-403).
- `ddgs` is not in the wheel's `Requires-Dist`. Hermes calls `DDGS(timeout=10).text(query, max_results)` with no backend argument (plugins/web/ddgs/provider.py:39-57).
- In ddgs 9.16.1, `backend="auto"` tries `wikipedia` and `grokipedia` first, then shuffles bing, brave, duckduckgo, google, mojeek, startpage, yahoo, yandex and others (ddgs/ddgs.py:89-95). Several of those hosts are not in `SEARCH_HOSTS`, so with this setup a search would trigger approval prompts or 60-second waits; this is read from code, not run.
- `brave-free` calls `https://api.search.brave.com/res/v1/web/search`.
- Extract works only with Firecrawl, Tavily, Exa or Parallel. Otherwise it returns "No web extract provider configured".
- No native vendor search over our transports. A Responses `web_search` exists only in the Codex/xAI transports.

## Using an MCP search tool instead

| Agent | MCP client | How our platform can inject it | Does it prefer MCP over built-in search? |
|---|---|---|---|
| Claude | Yes | ACP session (`per_session_mcp = true`) | Prefers MCP for fetch only (prompt). For search, deny `WebSearch` |
| Codex | Yes | ACP session, or `mcp_servers` | No. Set `web_search = "disabled"` to force MCP |
| Pi | Yes (1.2.0) | **Write `~/.pi/agent/mcp.json`** (pi-acp drops session MCP) | No built-in search, so MCP is the only tool. Use `direct` exposure |
| OpenClaw | Yes | **Write `mcp.servers` into openclaw.json** (no session MCP) | No documented preference. `web_search` is unavailable without a provider |
| Hermes | Yes (`[mcp]` extra) | ACP session, or `mcp_servers` in config.yaml | No preference. `web_search` is hidden when no backend is available |

Every agent also has a shell. `curl` to Bing, Baidu or DuckDuckGo HTML pages passes our proxy with no popup, but agents won't do this unprompted, and Codex read-only needs approval for commands.

## Search support at each vendor (whether the server-side tool works)

| Vendor | Anthropic-format server tool (Claude Code WebSearch) | Responses `web_search` (Codex) |
|---|---|---|
| Anthropic | Yes. $10 per 1,000 + tokens | No Responses endpoint |
| DeepSeek | Yes: `server_tool_use` and `web_search_tool_result` are supported (api-docs.deepseek.com/guides/anthropic_api) | Yes per the Search guide: "when … used through … Claude Code, or Codex, server-side tool calls already hit the Search and Fetch APIs". $0.75 per 1,000 successful requests from 2026-11-01 |
| OpenAI | n/a | Yes. $10 per 1,000 calls + content tokens |
| Qwen/DashScope | Unverified | Yes, `web_search` is a built-in tool for listed models such as qwen3.8-max. Price unverified; whether it accepts `external_web_access` is unverified |
| Kimi | Unverified. Kimi offers `/v1/tools/search`, `/v1/tools/search_pro` and `/v1/tools/fetch` REST endpoints; the per-call price is on its pricing page (not read) | Unverified |
| GLM | Coding Plan has a server-side search MCP built in ("模型服务端已内置联网搜索 MCP"), but the repo only accepts pay-as-you-go keys (vendors.rs:87). Pay-as-you-go: unverified | Unverified |
| MiniMax, Doubao, xAI, TokenHub, BytePlus | Unverified | Unverified |

## Costs (anything paid by the platform needs founder consent first)

- **Search at the vendor** (Claude, Codex): **¥0 platform cost**. It is billed to the user's own key. One Claude WebSearch call can mean up to 8 searches (up to $0.08 at Anthropic) plus the extra model request.
- **Gap:** llm-gw does not record `usage.server_tool_use.web_search_requests` (no match in crates/llm-gw/src). These charges are invisible in our usage records.
- **Key-free providers** (DuckDuckGo plugin, ddgs, Parallel-free): ¥0, unofficial, may hit bot challenges from Tokyo datacenter IPs (unverified). They count toward the 100 MiB/day per-instance limit (egress.rs:54).
- **Brave Search API, platform-paid** (not adopted; needs consent): $5 per 1,000 requests, with $5/month free credit (about 1,000 queries), 50 QPS, credit card required (brave.com/search/api). A platform key placed in the sandbox would break the "real keys never enter the sandbox" rule (config.rs:3). It should be proxied server-side or wrapped as an MCP tool.
- **Other paid search APIs** (Tavily, Exa, Firecrawl, Perplexity, Parallel, Zhipu, Kimi): prices not collected here (unverified). Each would need a cost list and consent.

## Repo issues these findings reveal

1. **No Claude settings.json is generated** (config.rs:163-187). WebFetch's `api.anthropic.com` preflight will hit our approval flow or fail. Fix: write `{"skipWebFetchPreflight": true}`.
2. **docs/agent-integration.md:152 is outdated:** Pi 1.2.0 has MCP. Platform tools could reach Pi through `mcp.json`.
3. **Codex sends the hosted `web_search` tool to every vendor by default.** For vendors that reject it, set `web_search = "disabled"` in the generated config.toml (config.rs:189-218).
4. **bridge.rs:45 (`EGRESS_INSTRUCTIONS`) tells every agent "Web search … usually work[s] directly".** That is false today for Pi, for OpenClaw without a provider, and for Hermes without a backend.

## Not verified (needs a sandbox or vendor test)

- WebSearch and Codex `web_search` behavior on Kimi, GLM pay-as-you-go, Qwen-Anthropic, MiniMax, Doubao, xAI and TokenHub (error vs. silently ignored).
- Whether the WebFetch preflight actually goes through our `HTTPS_PROXY`.
- `PI_OFFLINE` and MCP.
- OpenClaw search providers and the proxy; DuckDuckGo plugin 2026.10.3 compatibility in practice.
- Whether ddgs (primp) honors `HTTPS_PROXY`.
- Qwen and Kimi search prices; Kimi `$web_search` at ¥0.03 per call (third-party source only).
- What the "US-only" line in Claude Code's prompt means in practice.
- Codex `capabilities.external_web_access` config key at 0.160.1.

## Sources (all read 2026-11-04)

Repo:
- crates/catalog/manifests/{claude,codex,pi,openclaw,hermes}.toml
- crates/agent-shim/src/config.rs:3,163-187,189-218,245-275,276-345,352-400,421
- crates/agent-shim/src/bridge.rs:40-50
- crates/agent-shim/src/shim.rs:67-71
- crates/proto/src/egress.rs:7-39,54
- crates/proto/src/vendors.rs:82-125
- crates/llm-gw/src/body.rs:1
- docs/agent-integration.md:152
- docs/egress.md:9-13,36

Upstream packages (downloaded tarballs and wheels, inspected without installing):
- @anthropic-ai/claude-agent-sdk-linux-x64@0.3.296 (`claude` binary strings)
- @agentclientprotocol/claude-agent-acp@0.90.0
- @agentclientprotocol/codex-acp@2.2.2
- @earendil-works/pi-coding-agent@1.2.0, pi-ai@1.2.0, pi-acp@0.0.34
- openclaw@2026.10.3, @openclaw/duckduckgo-plugin@2026.10.10, @openclaw/brave-plugin@2026.10.10
- hermes-agent==0.19.0, ddgs 9.16.1
- They are in /tmp/claude-0/-home-user-Thinktin-Rust/6eda0341-41b9-5be1-b26f-1c110a526552/scratchpad/dl

Codex source:
- https://github.com/openai/codex/tree/rust-v0.160.1: codex-rs/core/src/config/mod.rs, core/src/tools/hosted_spec.rs, core/src/tools/spec_plan.rs, model-provider/src/provider.rs, models-manager/src/model_info.rs, tools/src/tool_spec.rs

Official docs:
- https://code.claude.com/docs/en/tools-reference
- https://code.claude.com/docs/en/data-usage
- https://code.claude.com/docs/en/feature-availability
- https://code.claude.com/docs/en/llm-gateway-protocol
- https://code.claude.com/docs/en/settings-reference
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool
- https://learn.chatgpt.com/docs/config-file/config-reference
- https://developers.openai.com/api/docs/guides/tools-web-search
- https://developers.openai.com/api/docs/pricing
- https://api-docs.deepseek.com/guides/anthropic_api
- https://api-docs.deepseek.com/guides/search
- https://help.aliyun.com/zh/model-studio/compatibility-with-openai-responses-api
- https://platform.kimi.com/docs/guide/use-web-search
- https://docs.bigmodel.cn/cn/coding-plan/mcp/search-mcp-server.md
- https://brave.com/search/api/
- https://docs.litellm.ai/docs/tutorials/claude_code_websearch (a gateway that runs Claude Code's `web_search` itself, for other providers)

Community source (unverified):
- https://cncsmonster.github.io/en/posts/claude-code-fix-webfetch-preflight/ (2026-05-07)


## providers

## Provider-native web search: research for "默认启用联网搜索" (read 2026-11-04)

No repository files were changed and nothing was committed. Scratch downloads are in /tmp/claude-0/-home-user-Thinktin-Rust/6eda0341-41b9-5be1-b26f-1c110a526552/scratchpad.

### Bottom line

1. **Without code changes, provider-native search already reaches the vendor in two of the five agents. Whether it works depends on the user's vendor.**
   - llm-gw forwards the request body byte for byte. It only rewrites `model` and adds `include_usage` (docs/llm-gateway.md:67; crates/llm-gw/src/proxy.rs:996-999). So a hosted search tool the agent puts in `tools` reaches the vendor unchanged.
   - **Claude Code** sends `{"type":"web_search_20250305","name":"web_search","max_uses":8,...}`. I found this string in the native binary bundled with claude-agent-sdk 0.3.296 (CLI 2.1.296).
   - **Codex** 0.160.1 sends the hosted `{"type":"web_search","external_web_access":false}` by default, also to custom providers. Source: codex `rust-v0.160.1`, `core/src/config/mod.rs` lines 3768-3769 (the default is `Cached`), `core/src/tools/hosted_spec.rs`, and `ProviderCapabilities::default()` with `web_search: true` in `model-provider/src/provider.rs`.
2. **Pi, OpenClaw and Hermes cannot trigger provider-native search on our gateway as configured.**
   - Pi core has no search tool.
   - OpenClaw's native OpenAI search is "not for proxy base URLs". Its Kimi and DeepSeek search providers call standalone `/tools/search` APIs with a provider key, and the sandbox has no such key.
   - Hermes' native options are xAI and OpenAI-Codex, and both need OAuth or a subscription.
   - For these three, provider-native search needs llm-gw to inject the tool or parameter. That is a new rewrite the gateway does not do today.
3. **Who pays.** The user's own key pays in every case, so our server cost is ¥0. The fees land on the user's bill and are not small; see the price column. Example: Claude Code allows up to 8 searches per WebSearch call, which is up to $0.08 on Anthropic.
4. **Gateway gaps.**
   - The usage meter records only tokens (crates/llm-gw/src/usage.rs:31-47 and 186-200). It ignores `usage.server_tool_use.web_search_requests` (Anthropic and DeepSeek), `usage.x_tools` (DashScope) and `usage.tool_usage.web_search` (Doubao). So search fees are neither shown nor capped by `daily_token_limit`.
   - The search runs on the vendor side, so it bypasses our egress proxy, SEARCH_HOSTS and egress_log. docs/egress.md:10 already notes this for Codex.
5. **"No setup by the user" breaks for some vendors.**
   - Doubao/Ark needs a component turned on in its console. Without it the call errors, and that applies to Codex's default tool too.
   - DashScope documents Anthropic-protocol search only on the workspace host `{WorkspaceId}.{region}.maas.aliyuncs.com`, with `cc_entrypoint=cli`.
   - Kimi Chat Completions needs the client to run a Formula round trip.
6. **Approval prompt risk for Claude.** WebSearch maps to ACP kind `fetch` (crates/agent-shim/src/claude_cli.rs:592). `PlanPolicy::default()` pre-authorizes nothing (crates/proto/src/domain.rs:391-393), and the shim runs with `--on-unlisted ask` (crates/orchestrator/src/exec.rs:124-125). So a Claude WebSearch probably asks the user, which conflicts with "no popup". Not tested.

### Repo facts that matter

- **Protocols per agent:**
  - Claude: anthropic-messages only (crates/catalog/manifests/claude.toml:36).
  - Codex: openai-responses only (codex.toml:30).
  - Pi and OpenClaw: completions, anthropic or responses (pi.toml:26, openclaw.toml:36).
  - Hermes: completions or anthropic (hermes.toml:25).
- **Platform MCP tools** are not delivered to Pi or OpenClaw (`per_session_mcp = false`, pi.toml:23 and openclaw.toml:27).
- **Config generators:** claude at crates/agent-shim/src/config.rs:163, codex at :189 (no `web_search` key, so the Codex default applies), pi at :245, openclaw at :276, hermes at :352.
- **Vendor list** (crates/proto/src/vendors.rs:128-458): DeepSeek, Qwen (cn/intl/us/hk), GLM (cn/intl), Kimi (cn/intl), MiniMax, Anthropic, OpenAI, Gemini, xAI, Mistral, Doubao/BytePlus, ERNIE, Hunyuan, StepFun.
- **Header whitelist:** `anthropic-beta`, `anthropic-version`, `openai-beta`, `accept` and `user-agent` are forwarded (docs/llm-gateway.md:77). Nothing search-specific is stripped.

### Per provider

**Anthropic**
- **How it is called:** a Messages tool `web_search_20250305` (basic), `_20260209` (dynamic filtering) or `_20260318` (`response_inclusion`). Options: `max_uses`, `allowed_domains` or `blocked_domains`, `user_location`.
- **Price:** "$10 USD per 1,000 searches, plus standard token costs". A search that errors is not billed.
- **Constraints:**
  - It is "enabled for your organization unless an administrator has disabled it". If disabled, the request gets a 400.
  - The basic version is ZDR-eligible; dynamic filtering is not.
  - Results carry `encrypted_content`, which must be sent back unchanged on the next turn or the request gets a 400.
  - `pause_turn` must be handled.
- **Through our gateway:** works for Claude Code as is.
- **Region:** search runs at Anthropic. No region restriction is stated on the page.

**OpenAI**
- **How it is called:** Responses tool `{"type":"web_search"}` with `filters` (up to 100 domains), `user_location`, `search_context_size` and `external_web_access` (false means cache-only). Chat Completions offers only the search models, such as `gpt-5-search-api`, and those always search.
- **Price:** web search $10/1k calls plus content tokens at model rates. The legacy `web_search_preview` on non-reasoning models is $25/1k.
- **Through our gateway:** works for Codex as is (cached mode). Whether cached mode is billed at the same $10/1k is not stated (unverified).

**DeepSeek**
- **Anthropic endpoint:** supports the `web_search_20250305` server tool, and the docs say Claude Code triggers it.
- **Responses:** `web_search` is supported with deepseek-v4-pro and "ignored with deepseek-flash".
- **Chat Completions:** no search parameter is documented.
- **Standalone API:** `POST /v1/tools/search` and `/v1/tools/fetch`.
- **Price:** Search ¥5 per 1,000 successful requests ($0.75), Fetch the same. Quote: "在 DeepSeek Harness/Claude Code/Codex 中…Server 端工具调用…将于北京时间 2026 年 11 月 1 日 00:00 起按次收取" (billing for searches made through Claude Code and Codex started 2026-11-01).
- **Limits:** Search 100 QPS, Fetch 25 QPS.
- **Through our gateway:** works for Claude Code on the Anthropic endpoint. For Codex it works only when the upstream model is v4-pro.
- **Unverified:** whether flash runs search on the Anthropic endpoint. Our vendors.rs:82 notes that unknown model names are mapped to flash there.

**Alibaba DashScope / Qwen**
- **How it is called:**
  - Chat: `enable_search: true` plus `search_options` (`forced_search`, `search_strategy` turbo, max, agent or agent_max; `freshness`; `assigned_site_list`).
  - Responses: `{"type":"web_search"}` (plus `web_extractor`).
  - Anthropic: `web_search_20250305` at `https://{WorkspaceId}.{region}.maas.aliyuncs.com/apps/anthropic`. Quote: "需在 system 中传入客户端标识 x-anthropic-billing-header: cc_entrypoint=cli; ，否则联网搜索不生效" (the client identifier must be in `system`, or search does not run).
- **Price per 1,000 calls:**
  - turbo ¥3 and max ¥4, Beijing only.
  - agent ¥4 in Beijing, Virginia, Hong Kong, Tokyo and Frankfurt; ¥73.392381 in Singapore.
  - Responses and Anthropic calls are billed like agent.
  - No free quota. The separate search MCP is free for the first 2,000 calls, then ¥29 per 1,000.
  - Search content is billed as input tokens.
- **Limits:**
  - 15 RPS per account. Above that, search is silently skipped.
  - Kimi models hosted on DashScope search only through Responses.
  - Search results can trigger content safety: `DataInspectionFailed` 400.
- **Through our gateway:**
  - Codex works as is for listed models.
  - For Claude, two things are unverified: whether our base `dashscope.aliyuncs.com/apps/anthropic` (vendors.rs:146) supports search, and whether `cc_entrypoint=sdk-ts` is accepted. The SDK sets `CLAUDE_CODE_ENTRYPOINT="sdk-ts"` when unset, and the CLI builds `cc_entrypoint=${CLAUDE_CODE_ENTRYPOINT ?? "unknown"}`; both are in the 0.3.296 package.
  - For Chat agents, `enable_search` would have to be injected by llm-gw. Whether it works alongside `tools` is unverified.

**Zhipu GLM**
- **How it is called:**
  - Chat: `tools: [{"type":"web_search","web_search":{"enable":true,"search_engine":"search_pro",...}}]`. The doc example uses glm-4-air; support on glm-5.x is unverified.
  - Responses (`/api/v1`): `WebSearchTool` with only `type: "web_search"`.
  - Standalone Web Search API, and a search MCP.
- **Price:** Search-Std ¥0.01 per call, Search-Pro ¥0.03, Sogou ¥0.05, Quark ¥0.05 (¥10-50 per 1,000).
- **Anthropic endpoint:** no server tool is documented. Built-in search for Claude Code exists only on GLM Coding Plan, which we reject (vendors.rs:87).
- **Through our gateway:**
  - Codex probably works. Whether `external_web_access` is rejected is unverified.
  - Claude: no.
  - Chat agents: needs injection.

**Moonshot / Kimi**
- **How it is called:**
  - Responses: `{"type":"web_search"}`. `external_web_access` and `user_location` are ignored. `search_context_size` and `blocked_domains` return `invalid_request_error`.
  - Messages (Anthropic): tools are `custom` only, so there is no server search.
  - Chat: search goes through the Formula API (`moonshot/web-search`), where the client must POST `/v1/formulas/{uri}/fibers`. The old `$web_search` is not in the current chat docs; a snippet said it was deprecated 2026-10-20 (unverified).
  - Standalone: `/v1/tools/search`, `/v1/tools/search_pro` and `/v1/tools/fetch`.
- **Price:** billed per executed search. The table renders client-side, so I could not read figures. A search snippet said $0.005 for `$web_search` and $0.002 Basic / $0.003 Pro (unverified).
- **Through our gateway:**
  - Codex works, but performs a live search even in cached mode.
  - Claude: no.
  - Chat agents: would need the gateway to run the Formula loop.

**ByteDance Doubao / Volcengine Ark**
- **How it is called:**
  - 豆包搜索 Custom 版: Responses `{"type":"web_search","sources":["doubao"]}`; Chat `web_search_options: {}`; Messages `web_search_20250305`. The page also covers Claude Code and Codex.
  - 联网内容插件 (web content plugin): Responses only, `{"type":"web_search","max_keyword":N}`.
- **Price:**
  - Plugin: 20,000 free per month, then ¥4 per 1,000; Toutiao, Douyin and Moji sources ¥6 per 1,000.
  - Custom 版: 500 free per month, 10 QPS. The unit price is not on the pages I read; a third-party figure is about ¥0.02 per call (unverified).
- **Constraints:**
  - Activation required. Quote: "调用工具之前，请确认您已经按照本文说明开通相应的组件，否则调用时将会产生错误" (turn on the component first, or calls will error).
  - Quote: "使用 Chat API 时，如果同时传入自定义工具和 web_search_options ，系统只会执行自定义工具，联网搜索不会生效" (with any custom tools present, Chat search does not run). So Chat injection is useless for agents.
  - The `caching` parameter combined with tools returns a 400.
- **Through our gateway:** Codex's default tool lacks `sources:["doubao"]`, so it takes the plugin path and probably errors unless the plugin is turned on. A live test is needed.

**Baidu Qianfan / ERNIE**
- **How it is called:** Chat v2 top-level `web_search: {enable, enable_citation, enable_trace, search_mode, search_number, reference_number}`. Models: ernie-5.1, ernie-5.0, ernie-x1.1 and ernie-4.5-turbo; "ernie系列模型不支持强制搜索" (ERNIE models do not support forced search). The page was updated 2026-07-09.
- **Price:** not on the page. IT之家 (2026-10-30) reports a promotional ¥4.9 per 1,000 for Baidu's search API (unverified).
- **Not documented:** search on the Anthropic endpoint, and combining with `tools`.

**MiniMax** (unverified, third-party sources): Anthropic `web_search_20250305` server tool in beta, about $0.01 per request.

**Tencent Hunyuan TokenHub** (unverified): the old platform's search went offline with the platform; the new search in TokenHub is "to be announced".

**Not researched:** Gemini, xAI, Mistral, StepFun.

### Can each agent trigger it?

- **Claude Code** (ACP and CLI): yes, through WebSearch. It works when the vendor is Anthropic or DeepSeek. Doubao works with activation. DashScope and MiniMax are unverified. Kimi, GLM pay-as-you-go and ERNIE: no.
  - Per-turn cap: `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION`.
  - Possible approval prompt (bottom line, item 6).
- **Codex:** yes, by default, and server-side, so there is no ACP prompt. It works for OpenAI (cached), DeepSeek v4-pro, Kimi, GLM (probably), DashScope models in the list, and Doubao only with activation. Setting `web_search = "disabled"` would remove the tool.
- **Pi:** no native trigger. Third-party extensions exist, such as `pi-web-search` (Gemini, OpenAI, Anthropic) and `pi-deepseek-search` (needs `DEEPSEEK_API_KEY` in the sandbox). Gateway injection would work only if Pi round-trips `server_tool_use` and `web_search_call` items; unverified.
- **OpenClaw:** no on our proxy base URL. Its DeepSeek, Kimi, MiniMax, Gemini and Grok providers need provider keys inside the sandbox.
- **Hermes:** no. Its keyless ring (Exa, Parallel, Firecrawl, Keenable) is not provider-native and its hosts are not in SEARCH_HOSTS.

### What building it would take (options, not decisions)

- **A. Count and cap search fees.** llm-gw would parse `server_tool_use`, `x_tools` and `tool_usage` into usage records and budgets. Needed whatever option is chosen.
- **B. Inject a search tool or parameter per vendor and protocol.**
  - Anthropic protocol: `web_search_20250305`.
  - Responses: `{"type":"web_search"}`, plus `sources:["doubao"]` for Ark.
  - Chat: `enable_search` for DashScope; the `web_search` tool for GLM.
  - Not possible for Doubao Chat, Kimi Chat, DeepSeek Chat or OpenAI Chat.
  - This changes the "only `model` and include_usage" body rule (docs/llm-gateway.md:67), and each harness must tolerate the hosted-tool blocks.
- **C. A platform search tool backed by the vendor's standalone API with the user's key.** Candidates: DeepSeek `/v1/tools/search` (¥5 per 1,000), Kimi `/v1/tools/search`, the Zhipu Web Search API (from ¥0.01 per call), and DashScope MCP. It reaches Pi and OpenClaw only if they get MCP or a native tool, since `per_session_mcp` is false for both.
- **Gap left either way:** users whose vendor has no search (Kimi or GLM on Claude, Mistral, StepFun, Hunyuan, and possibly ERNIE) need a fallback, such as search pages through the egress proxy, or a paid search API. A paid API needs the founder's cost approval first.

### Unverified (needs live tests with real keys)

- Whether DashScope accepts `cc_entrypoint=sdk-ts` or `sdk-cli`, and its non-workspace host.
- How GLM, DashScope and Ark Responses handle Codex's `external_web_access` field.
- Whether DeepSeek flash searches on the Anthropic endpoint.
- Kimi, Doubao Custom, ERNIE and MiniMax unit prices.
- OpenAI cached-mode billing.
- Whether Claude WebSearch actually prompts for approval in our runs.
- Whether DashScope `enable_search` and ERNIE `web_search` work together with `tools`.
- Whether Pi, OpenClaw and Hermes round-trip hosted-tool output.

### Sources (all read 2026-11-04)

- Anthropic web search tool: https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool
- Anthropic server tools: https://platform.claude.com/docs/en/agents-and-tools/tool-use/server-tools
- Claude Code tools reference (WebSearch section): https://code.claude.com/docs/en/tools-reference
- Claude Code gateway compatibility (attribution block): https://code.claude.com/docs/en/llm-gateway-protocol
- OpenAI web search guide: https://developers.openai.com/api/docs/guides/tools-web-search
- OpenAI pricing: https://developers.openai.com/api/docs/pricing
- Codex config reference: https://learn.chatgpt.com/docs/config-file/config-reference
- Codex source at the pinned tag: https://raw.githubusercontent.com/openai/codex/rust-v0.160.1/codex-rs/core/src/tools/hosted_spec.rs (also `core/src/config/mod.rs`, `core/src/tools/spec_plan.rs`, `model-provider/src/provider.rs`)
- DeepSeek search and fetch: https://api-docs.deepseek.com/guides/search
- DeepSeek pricing: https://api-docs.deepseek.com/zh-cn/quick_start/pricing
- DeepSeek Anthropic API: https://api-docs.deepseek.com/guides/anthropic_api
- DeepSeek Responses API: https://api-docs.deepseek.com/guides/responses_api
- DashScope web search: https://help.aliyun.com/zh/model-studio/web-search and https://www.alibabacloud.com/help/en/model-studio/web-search
- Zhipu pricing: https://docs.bigmodel.cn/cn/guide/start/pricing.md
- Zhipu web search: https://docs.bigmodel.cn/cn/guide/tools/web-search.md
- Zhipu Responses: https://docs.bigmodel.cn/cn/guide/develop/responses/introduction.md and https://docs.bigmodel.cn/openapi/openapi-responses.json
- Zhipu Claude-compatible API: https://docs.bigmodel.cn/cn/guide/develop/claude/introduction.md
- Zhipu search MCP: https://docs.bigmodel.cn/cn/coding-plan/mcp/search-mcp-server.md
- Kimi web search pricing: https://platform.kimi.com/docs/pricing/websearch.md
- Kimi Responses API: https://platform.kimi.com/docs/api/responses.md
- Kimi Messages API: https://platform.kimi.com/docs/api/messages.md
- Kimi official tools: https://platform.kimi.com/docs/guide/use-official-tools.md
- Kimi web search best practices: https://platform.kimi.com/docs/guide/best-practices-for-web-search.md
- Volcengine Ark web search tool: https://docs.volcengine.com/docs/82379/1756990 (page updated 2026-11-03)
- Volcengine web content plugin pricing: https://docs.volcengine.com/docs/82379/1338550
- Doubao Search Custom 版: https://docs.volcengine.com/docs/Networkedsearch/Networkedsearch-2?lang=zh
- Qianfan web search: https://cloud.baidu.com/doc/qianfan-docs/s/Wm8r4sw29
- OpenClaw web tools: https://docs.openclaw.ai/tools/web
- Hermes web search: https://hermes-agent.nousresearch.com/docs/user-guide/features/web-search/
- pi-deepseek-search package: https://pi.dev/packages/pi-deepseek-search
- Secondary (not official): https://ithome.com/1/020/165.htm and https://minimax-ai.chat/docs/server-tools-web-search/
- npm packages inspected locally: @agentclientprotocol/claude-agent-acp@0.90.0, @anthropic-ai/claude-agent-sdk@0.3.296 and claude-agent-sdk-linux-x64@0.3.296



## apis


# Paid web search APIs for a server-side `web_search` tool (research done 2026-11-04)

No repository files were changed and nothing was committed. Everything priced below is a paid service, so none of it should be used until the founder approves the cost.

## 1. Summary

- **Cheapest options for Chinese queries, as officially listed this week:**
  - DeepSeek Search: ¥5 per 1,000 searches (or $0.75 per 1,000). It opened on 2026-10-17. It returns snippets only unless you set `need_content=true`, and allows 100 queries per second.
  - Alibaba Cloud IQS "LiteBasic": ¥8 per 1,000. It is billed through the aliyun.com account the founder already has.
  - Kimi Web Search Basic: ¥10 per 1,000.
  - Zhipu `search_std`: ¥10 per 1,000.
  - Tencent 元宝搜索 (Yuanbao Search), fastest tier: ¥14 per 1,000.
- **Baidu's standard price is ¥36 per 1,000**, with 1,500 free searches a month. A promotional price of ¥4.9 per 1,000 runs until 2026-12-31, but only secondary sources describe its terms.
- **Western providers cost about ¥7 to ¥34 per 1,000:** Brave $5, Perplexity $5 (its "fast" mode $1), Tavily $8, and Exa $4 plus extra for snippets.
- **Serper costs $0.30 to $1 per 1,000.** It resells scraped Google results, which carries legal and terms-of-service risk.
- **Not available:**
  - Google's Custom Search JSON API is closed to new customers.
  - Bing Search APIs were retired on 2025-08-11.
- **Cost at the assumed usage** (20 searches per active user per day):
  - 10 users: about ¥30–60/month with the cheapest Chinese providers. This fits inside the ¥390–450/month server budget (docs/deploy-aliyun-sg.md:190).
  - 100 users: about ¥300–600/month. That is already more than the entire current server budget.
  - 1,000 users: about ¥3,000–6,000/month.
  - Any Western provider costs roughly 3–7 times as much.
- **Recommended setup:**
  - Call search from our Tokyo servers as a platform MCP tool. It would be a new provider in `ToolSet` (crates/orchestrator/src/tools.rs:410-432), exposed through crates/agent-shim/src/bridge.rs.
  - The sandbox never contacts the search vendor, and no vendor key goes into the sandbox.
  - Return only title, URL, site name, date and a snippet capped at about 300 characters. Discard every content, summary or full-text field the vendor returns.
  - When an agent opens a result page, that request still goes through the egress proxy and the per-site approval prompt.
  - Use DeepSeek as the main provider and IQS or Kimi/Zhipu as the fallback.
  - Set a per-user daily cap on searches.

## 2. Assumptions

- **Volume:** monthly searches = active users × 20 per day × 30 days.
  - 10 users: 6,000/month
  - 100 users: 60,000/month
  - 1,000 users: 600,000/month
- **Load:** at 1,000 users the average is about 0.23 queries per second, so every rate limit listed below is sufficient.
- **Exchange rate:** ¥6.72 per US dollar. This is the PBoC central parity on 2026-10-16 as reported by Sina Finance. I could not find a November rate (unverified).
- **Accounts:** the founder uses a real-name-verified **domestic aliyun.com** account, and the servers are in Tokyo (docs/deploy-aliyun-sg.md:4).
- **Repository context:**
  - The founder's decision to turn search on by default is recorded in docs/egress.md:36.
  - `SEARCH_HOSTS` is defined in crates/proto/src/egress.rs:23-39. It already contains `api.search.brave.com`.
  - The model vendors users can bring keys for are listed in crates/proto/src/vendors.rs:130-446. They include DeepSeek, Qwen, GLM/Z.ai, Kimi, MiniMax, Anthropic, OpenAI, Gemini, xAI, Mistral, Doubao, ERNIE, Hunyuan and StepFun.

## 3. Provider by provider (all pages read 2026-11-04)

### Chinese providers

**DeepSeek Search (with a separate Fetch API)**
- **Price:**
  - ¥5 per 1,000 successful requests, or $0.75 per 1,000 on the international site.
  - Billing per call started 2026-11-01 00:00 Beijing time.
  - No free tier is listed.
- **Endpoint and limits:** `POST https://api.deepseek.com/v1/tools/search`, 100 queries per second per account. It uses the same key as DeepSeek's models.
- **What it returns:**
  - `snippet` of "typically 100 to 200 characters".
  - `summary`, a longer text written for models.
  - `content`, the page text, which is empty unless `need_content=true`.
  - Fetch is a separate endpoint that returns full pages as Markdown.
- **Index and quality:** the index is DeepSeek's own. No independent test of Chinese-language quality exists yet (unverified).
- **Reachability:** reachable from outside China. I got a 401 without a key from a US machine in this session.
- **Account requirements and terms:**
  - Account and payment requirements are unverified.
  - The docs say nothing about caching or data retention (unverified).
- **Plan:** drop `summary` and `content`.

**Alibaba Cloud IQS (信息查询服务, information query service)**
- **Price per 1,000:**
  - CNLiteBasic ¥8
  - CNAuto ¥18
  - Generic ¥42, falling to ¥30 at very high daily volume
  - GlobalAdvanced ¥56
  - A summary add-on costs ¥2.8 per 1,000.
- **Rate limit:** 10 queries per second by default.
- **Account requirements:**
  - Alibaba Cloud real-name verification, which the founder already has.
  - One instance per account.
- **Free trial:** 15 days, 1,000 calls for a personal account and 5,000 for a company account. This comes from a search snippet of help.aliyun.com and is unverified.
- **Endpoint:** `cloud-iqs.aliyuncs.com`.
- **What it returns:** results include `snippet` and `mainText`. Whether `mainText` (the page body) is returned by default is unverified, so strip it.
- **Advantage:** it is billed on our existing Alibaba Cloud bill, so there is no new vendor to sign up with.

**Kimi (Moonshot)**
- **Price:**
  - Web Search Basic `/v1/tools/search`: ¥0.01 per call. On the international site it is $0.002.
  - Web Search Pro: ¥0.015, or $0.003 international.
  - The `web_search` tool built into the model API: ¥0.03, or $0.005 international.
  - URL Fetch: ¥0.01, or $0.002 international.
  - Only successful calls with non-empty results are billed.
- **What it returns:** Basic returns a `snippet`. It returns `text` (the full page) only when `include_content=true`. `limit` can be 1–20.
- **Rate limits:** depend on the account tier and the number is unverified. Real-name and payment requirements are also unverified.

**Zhipu (BigModel)**
- **Price per call:**
  - `search_std` ¥0.01
  - `search_pro` ¥0.03
  - `search_pro_sogou` and `search_pro_quark` ¥0.05 each
- **Endpoint:** `https://open.bigmodel.cn/api/paas/v4/web_search`.
- **What it returns:** `content` is described as a summary (内容摘要). `content_size=medium` gives the short summary, and `high` gives a more detailed one.
- **Limits:** up to 50 results. Concurrency is capped (error code 1701), but the number is not given.
- **Coverage:** according to Zhipu's docs, the Sogou engine covers Tencent-ecosystem and Zhihu content.
- **International (Z.ai):** the web search tool costs $0.01 per use, which is expensive.

**Tencent 元宝搜索 (Yuanbao Search, API service `wsa`)**
- **Price per 1,000** (page updated 2026-10-09):
  - Fastest tier ¥14
  - Standard ¥20
  - Flagship ¥26, for companies only
- **Prepaid packs (standard tier):** 50,000 calls for ¥950, 1 million for ¥18,500.
- **Account requirements:** personal real-name or company verification.
- **Index:** described as "hundreds of billions" of entries.
- **Unverified:**
  - Free quota (Baidu Baike says 2,000 a month)
  - Rate limits
  - Whether results include page content

**Baidu Qianfan 百度搜索 (Baidu Search API)**
- **Endpoint:** `POST https://qianfan.baidubce.com/v2/ai_search/web_search`.
- **Price per call** (billing page updated 2026-11-02):
  - Domestic content, standard: ¥0.036
  - Domestic content, enhanced: ¥0.04
  - Domestic content, flagship: ¥0.072
  - Foreign content, enhanced: ¥0.072
- **Free quota:** 1,500 a month, released at about 50 a day.
  - An older price page (updated 2026-10-29) still says 100 a day.
- **Prepaid packs (valid one year):** 10,000 for ¥352, 100,000 for ¥3,420, 1 million for ¥30,600.
- **Limits:** 3 queries per second by default and 100,000 per day.
- **Account requirements:** Baidu Cloud real-name verification.
- **What it returns:**
  - `content` is "up to 2,000 characters of related original-text excerpt (currently the same as snippet)".
  - Truncate it ourselves.
  - Result types include `web`, `video`, `image` and Baidu's direct-answer cards (`aladdin`).
- **Promotion:**
  - Announced 2026-10-30 at "as low as ¥4.9 per 1,000".
  - According to drweb.de (secondary), it runs until 2026-12-31 and is capped at 1 million calls.
  - drweb.de also says the normal price after the promo quota is ¥40 per 1,000.
  - Unverified on Baidu's own pages.
- **Quality:** Baidu has the largest Chinese index, but I did not test it (unverified).

**Bocha (博查)**
- **Price:**
  - Web Search ¥0.036 per call and AI Search ¥0.060, according to Bocha's own product document dated 2025-05.
  - A GitHub issue from 2026-09 says about ¥0.03–0.04 per call.
  - The current official price page needs a login, so the price is unverified.
- **Billing:** prepaid top-up only (terms §5.4, 2025-05-29).
- **Free calls:** 1,000 free calls for new users plus 1,000 more via a promo code, according to Zhihu (unverified).
- **Throughput:** up to 2,000 queries per second claimed. The real limit depends on how much you have topped up (unverified).
- **What it returns:** `snippet` plus an optional long `summary`. Set `summary=false`.
- **Sources claimed:** web pages plus Douyin, WeChat official accounts, Xiaohongshu, Zhihu and Weibo (product document p.4).
- **Terms:** they forbid scraping or collecting data from the service and require reviewing end-user inputs and outputs. They say nothing about caching or AI use.

**Metaso (秘塔)**
- **Price:** ¥0.03 per call, with 5,000 free points (about 500 searches) at sign-up. These figures come from news reports from 2025-07 and 2025-12. No official price page was reachable, so they are unverified.
- **What it returns:** one search mode returns the full text of the source pages, and there is a separate Reader (full page) endpoint. Force the snippet mode.

### International providers

**Brave Search API**
- **Price:** Search plan $5 per 1,000, with $5 in free credits every month (1,000 searches) and 50 queries per second.
  - The same page also says "Up to $20 in free calls every month", which conflicts with the $5 figure.
- **Terms of service:**
  - §3(b)(i): no storing or caching beyond "transient storage required for operation".
  - §3(b)(xii): no redistributing or reselling results.
  - §3(b)(xiii): no using results to train or improve AI models.
  - Grounding a model at inference time is not explicitly addressed.
  - The FAQ says storing results needs a plan with storage rights.
  - Zero data retention is Enterprise-only.
- **What it returns:** a description snippet plus optional `extra_snippets`. Do not use the "LLM Context" endpoint, which returns passages from pages.
- **Chinese quality:** Brave uses its own index. Chinese coverage is probably weaker (unverified).
- **Other:** whether a card is needed is unverified.

**Tavily (`/search` endpoint)**
- **Price:**
  - 1,000 free credits a month, then $0.008 per credit pay-as-you-go.
  - Monthly plans: $30 for 4,000 credits, $100 for 15,000, $220 for 38,000, $500 for 100,000.
  - Basic, fast and ultra-fast searches cost 1 credit; advanced costs 2.
- **Rate limits:** 100 requests per minute on a development key, 1,000 on a production key.
- **What it returns:**
  - `content` is up to 3 chunks of about 500 characters each, taken from the page.
  - `include_raw_content` is off by default.
- **Terms (2026-05-04):**
  - §6.5: Tavily may keep inputs and outputs to train AI models.
  - Resale is restricted, but building it into your own application is allowed.
  - No zero-retention option in the privacy policy.

**Exa**
- **Price per 1,000** (each covers up to 10 results):
  - `lite` $4
  - `auto` and `fast` $7
  - `deep` $12
  - $10 in free credits, reset every month.
- **Snippets cost extra:** `/search` returns no text or highlights by default. Content is billed separately at $1 per 1,000 pages per content type, so snippets for 10 results add about $10 per 1,000 searches.
- **Rate limit:** 10 queries per second.
- **Terms:**
  - §1.2(c): Exa gets a perpetual licence to user input and output.
  - §4.2(a): no copying or storing except the browser cache.
  - §4.2(e): no reselling without consent.

**Perplexity Search API**
- **Price:** $5 per 1,000, or $1 per 1,000 with `search_type:"fast"`. No free tier. Failed requests are not billed.
- **Rate limit:** 50 query units per second, the same on every tier.
- **What it returns:** `snippet` is "Content snippet extracted from the page", sized by `max_tokens_per_page`, so it is page content. Set it low.
- **Terms (2026-01-23):** §2.3.3 says Perplexity will not train on customer content. Output may be displayed within your own application.

**Serper (scrapes Google results)**
- **Price:** 2,500 free queries once.
  - $50 for 50,000 credits ($1 per 1,000)
  - $375 for 500,000 ($0.75 per 1,000)
  - $1,250 for 2.5 million ($0.50 per 1,000)
  - $3,750 for 12.5 million ($0.30 per 1,000)
  - Credits expire after 6 months.
- **Rate limits:** 50–300 queries per second.
- **What it returns:** only the snippets on Google's results page.
- **Risks:**
  - Its terms (2024) forbid mirroring and are silent on AI use.
  - Legal risk: Google sued SerpApi in 2025-12 over scraping. The case was reportedly dismissed with leave to amend in 2026-07 (secondary reports; whether Google refiled is unverified).

**SerpApi**
- **Price:**
  - Free: 250 searches a month
  - $75 for 5,000
  - $150 for 15,000
  - $725 for 100,000
  - $3,750 for 1 million
- **Legal Shield:** a US legal-indemnity add-on, included from the $150 plan up.
- **Engines:** SerpApi also offers Baidu as a search engine (unverified, from memory).

**Other options checked**
- **Google Custom Search JSON API:** "closed to new customers". Existing customers have until 2027-01-01.
- **Bing Search APIs:** retired 2025-08-11. The replacement, "Grounding with Bing Search", works only inside Azure AI Agents. Its price is unverified ($14–35 per 1,000 in secondary sources).
- **Jina `s.jina.ai`:**
  - Each request costs at least 10,000 tokens. New keys get 10 million free tokens.
  - Limits: 100 requests per minute with a free key, 1,000 with a premium key.
  - By default it returns the top 5 results with their full page content, which would bypass our per-site approval.
  - The price per token and a "no-content" mode are unverified.
  - Avoid it.
- **Cloudflare Web Search** (page dated 2026-10-02): routes to Ceramic.ai at $0.25 per 1,000, Exa at $7 or Linkup at $5. Chinese-language quality is unverified.
- **Volcano Engine (ByteDance) search:** about ¥4 per 1,000, plus "vertical sources" at ¥6 per 1,000 with 20,000 free a month. These figures come from aitoollab.cn (2026-10-19) only and are unverified on Volcano Engine's site.

## 4. Estimated monthly cost

Prices are converted to CNY at ¥6.72 per dollar. Free tiers that renew every month are subtracted.

| Provider (tier) | 10 users (6k/month) | 100 users (60k) | 1,000 users (600k) |
|---|---|---|---|
| DeepSeek (¥5 per 1k) | ¥30 | ¥300 | ¥3,000 |
| Baidu promo ¥4.9 per 1k (until 12-31, unverified) | ¥29 | ¥294 | ¥2,940 |
| Alibaba IQS CNLiteBasic (¥8) | ¥48 | ¥480 | ¥4,800 |
| Serper (~$1 down to $0.55 per 1k) | ~¥56 | ~¥403 | ~¥2,218 |
| Kimi Basic, China site (¥10) / Zhipu `search_std` (¥10) | ¥60 | ¥600 | ¥6,000 |
| Kimi Basic, international ($2) | ¥81 | ¥806 | ¥8,064 |
| Tencent Yuanbao fastest / standard (¥14 / ¥20) | ¥84 / ¥120 | ¥840 / ¥1,200 | ¥8,400 / ¥12,000 |
| Perplexity fast ($1) | ¥40 | ¥403 | ¥4,032 |
| Exa lite, no snippets ($4, minus $10) | ¥94 | ¥1,546 | ¥16,061 |
| Exa lite with highlights (~$14) | ¥497 | ¥5,578 | ¥56,381 |
| Baidu standard (¥36, minus 1,500 free) | ¥162 | ¥2,106 | ¥21,546 |
| Brave ($5, minus $5 credit) | ¥168 | ¥1,982 | ¥20,126 |
| Metaso (¥30, unverified) / Zhipu `search_pro` (¥30) | ¥180 | ¥1,800 | ¥18,000 |
| Perplexity ($5) | ¥202 | ¥2,016 | ¥20,160 |
| Bocha (¥36, 2025 price) | ¥216 | ¥2,160 | ¥21,600 |
| Tavily basic (cheapest plan plus overage) | ¥269 | ¥2,661 | ¥30,240 |
| SerpApi (smallest plan that covers the volume) | ¥1,008 | ¥4,872 | ¥25,200 |

Free tiers alone (Brave 1,000 + Tavily 1,000 + Exa about 2,500 without snippets + Baidu 1,500 a month) only just add up to the 10-user volume. That would mean depending on four vendors, so I don't recommend it.

## 5. Keeping results to snippets (so search does not bypass per-site approval)

The search call runs on our servers, so the vendor's host never needs to be in `SEARCH_HOSTS`. The server must remove page content before results reach the agent:

| Provider | Setting or field to handle |
|---|---|
| DeepSeek | `need_content=false`; drop `summary` |
| Kimi | `include_content=false`; don't use Pro chunks or `/fetch` |
| Zhipu | `content_size=medium` |
| Baidu | truncate `content` |
| Bocha | `summary=false` |
| Tavily | keep `include_raw_content` off and `chunks_per_source=1`, or use the ultra-fast mode |
| Perplexity | small `max_tokens_per_page` |
| Brave | no LLM Context endpoint, no `extra_snippets` |
| Exa | highlights only |
| IQS | drop `mainText` |
| Metaso | snippet mode only |

On top of that, apply our own limit of about 300 characters per snippet. Also share no cache between users: Brave §3(b)(i) and Exa §4.2(a) forbid storing results, and the other vendors' terms are unclear.

## 6. Not verified

- Real Chinese-language quality for every provider. I had no keys; a bake-off of about 50 queries is needed.
- Reachability from the Tokyo servers specifically. Only a US machine was tested, and all endpoints answered (401, 403 or 422 without a key).
- Reachability of the Western APIs from mainland China.
- Real-name and payment requirements for DeepSeek, Kimi, Zhipu, Bocha and Metaso.
- Current Bocha and Metaso prices.
- Terms on Baidu's promotion.
- Tencent's free quota.
- Volcano Engine pricing.
- Jina pricing.
- Retention and caching terms of the Chinese vendors.
- Cross-border personal-information rules: sending Chinese users' queries to US vendors may need review.

## Sources (all read 2026-11-04)

**Repository**
- crates/proto/src/egress.rs:23-39
- crates/orchestrator/src/tools.rs:410-432
- crates/agent-shim/src/bridge.rs:45
- crates/proto/src/vendors.rs:130-446
- docs/egress.md:36
- docs/deploy-aliyun-sg.md:4,190

**International providers**
- https://brave.com/search/api/
- https://api-dashboard.search.brave.com/documentation/resources/terms-of-service
- https://docs.tavily.com/documentation/api-credits
- https://docs.tavily.com/documentation/api-reference/endpoint/search
- https://docs.tavily.com/documentation/rate-limits
- https://www.tavily.com/terms
- https://www.tavily.com/privacy
- https://exa.ai/pricing
- https://docs.exa.ai/reference/search
- https://docs.exa.ai/reference/rate-limits
- https://exa.ai/assets/Exa_Labs_Terms_of_Service.pdf
- https://docs.perplexity.ai/getting-started/pricing
- https://docs.perplexity.ai/guides/usage-tiers
- https://docs.perplexity.ai/api-reference/search-post
- https://www.perplexity.ai/hub/legal/perplexity-api-terms-of-service
- https://serper.dev/
- https://serper.dev/terms
- https://serpapi.com/pricing
- https://developers.google.com/custom-search/v1/overview
- https://learn.microsoft.com/en-us/lifecycle/announcements/bing-search-api-retirement
- https://jina.ai/reader/
- https://developers.cloudflare.com/web-search/providers/

**Chinese providers**
- https://api-docs.deepseek.com/zh-cn/quick_start/pricing
- https://api-docs.deepseek.com/quick_start/pricing
- https://api-docs.deepseek.com/guides/search
- https://help.aliyun.com/zh/document_detail/2862023.html
- https://help.aliyun.com/zh/document_detail/2871439.html
- https://help.aliyun.com/zh/document_detail/2869993.html
- https://platform.kimi.com/docs/pricing/tools
- https://platform.kimi.ai/docs/pricing/websearch
- https://platform.kimi.ai/docs/api/tools-search.md
- https://docs.bigmodel.cn/cn/guide/tools/web-search
- https://docs.bigmodel.cn/api-reference/%E5%B7%A5%E5%85%B7-api/%E7%BD%91%E7%BB%9C%E6%90%9C%E7%B4%A2
- https://docs.z.ai/guides/overview/pricing
- https://cloud.tencent.com/document/product/1806/121798
- https://cloud.tencent.com/document/product/1806/121802
- https://cloud.tencent.com/document/product/1806/121799
- https://cloud.baidu.com/doc/qianfan/s/1mh4sv6c4
- https://cloud.baidu.com/doc/qianfan/s/2mh4su4uy
- https://cloud.baidu.com/doc/qianfan-docs/s/Jm8r1826a
- https://cloud.baidu.com/doc/qianfan/s/Mmh4sv6ec
- https://open.bochaai.com/
- https://open.bochaai.com/terms-of-service
- Bocha product document PDF (2025-05): https://mkp-res.hc-cdn.com/marketplace/public/appv2/attachment/FE5/A96/96F/0000000000FE5A9696F.20250527042304.feac985174234808a69f64e899bd6792.pdf
- https://metaso.cn/search-api/playground

**Secondary sources**
- https://www.qbitai.com/2026/10/506771.html
- https://www.drweb.de/baidu-such-api-ki-agenten-preis/
- https://www.ithome.com/1/015/711.htm
- https://www.woshipm.com/ai/6480510.html
- https://www.aitoollab.cn/articles/deepseek-search-api-price-2026-10/
- https://www.digitalapplied.com/blog/web-search-apis-for-ai-agents-compared-2026
- https://github.com/TencentCloud/Octop/issues/923
- https://github.com/voidmuse-dev/voidmuse/blob/main/doc/zh/bochaSearchConfig.md
- https://www.sohu.com/a/964558635_122496371
- https://www.theregister.com/2026/02/21/serpapi_google_scraping_lawsuit/
- https://www.gigazine.net/gsc_news/en/20260723-google-loses-lawsuit-against-serpapi
- Exchange rate: https://cj.sina.com.cn/articles/view/1663612603/6328b6bb0200248kg



## 核对时对初稿改了什么


1. **加上“东京还没部署”。** 服务机还没买（进度文件第 14 行），所以“现状”说的是按现在的代码上线会怎样。“现有服务机够用”改成“计划买的 2 核 4G 服务机”（`deploy-aliyun-sg.md:182`）。第 1 步“从东京测”补上了办法和花费：等服务机，或者临时开一台按量 ECS，也要你同意。
2. **补上逐站审批这一条。** 原稿没指出厂商自带搜索会替 agent 读网页正文，绕过“别的网站要问用户”：Anthropic 把搜到的内容放进上下文，OpenAI 有 `open_page`，DeepSeek 用 Fetch，这几条都在官方文档里重读过。现在第 1 节、第 2 节表格（新加一行）、第 4 节第 3 步、第 6 节都写了；第 3 步改成“要你定”，不再直接说打开省钱。
3. **改正 Codex 免批准的说法。** 原稿说“没查到现成的开关、可能要 shim 按工具名批准”，不对。Codex 0.160.1 源码里有逐个工具的 `approval_mode`，默认 `auto` 模式下带 `readOnlyHint: true` 的 MCP 工具不用批准。我们的桥没带这个标记（`bridge.rs:310`），这才是现在要批准的原因。方案改成给 `web_search` 加只读标记，工作量也跟着调小了。
4. **Claude 的 ACP 放行，从“没核实”改成“代码上看应该行，没实测”。** 依据是适配器读 user/project/local 设置，而且先按规则放行、再交给适配器（`acp-agent.js:7897`、`7036-7041`）。
5. **补上通义新加坡的价格。** Codex 走通义新加坡（我们的 `qwen-intl`）时，每千次搜索约 ¥73，不是 ¥4（百炼官方价格表已重读）。智谱国际站 Z.ai 每次 $0.01 也补上了。
6. **Kimi 价格标成没核实。** 官方价目表是空的，原稿把 ¥10/千次当成核实过的。
7. **DeepSeek 的说法改正。** “10-17 开放”只有二手来源，官方页面没写日期；另外补上没有免费额度、要先充值、长摘要和正文要丢掉这几点。
8. **改正“国外接口贵 3–7 倍”。** 现在写成 Brave、Tavily、Exa 贵 3–10 倍；Perplexity 快速档 $1/千次（已核实）、Serper、Ceramic 并不贵。费用表加了 Perplexity 快速档一行；“最便宜”改成“国内正式价里最便宜”。
9. **Serper 那条改正。** 原稿说“谷歌正在打官司”，改成：2025-12 起诉 SerpApi，据报 2026-07 被驳回、可以再告，后来有没有再告没核实。必应接口改成“已下线”，不只是“不能新开”。
10. **Claude 各厂商的说法放软。** Kimi、智谱、文心原稿写“不能”，改成“文档里没有，大概不能，没实测”。通义改成“大概不行”，因为我们用的是通用地址。也写明了混元、阶跃、xAI 没查。
11. **补上 OpenClaw 要关自带搜索。** 写 `tools.web.search.enabled: false`。原稿说它“本来就没有”，其实它的 `web_search` 默认是开的，只是没有搜索服务。
12. **补上 Claude 读一篇文章可能弹两次窗。** 一次是 Claude 自己的 WebFetch 批准，一次是出口代理，加成要定的第 7 项。
13. **钱的说法改正。** 搜索费是在服务器预算之外另加的；100 人时范围改成 ¥300–600；切到 IQS 后，10 人最坏情况会超过 ¥100。
14. **网关记搜索次数挪到第 3 步。** 这件事只在保留厂商搜索时才需要，保留的话要提前到上线前。第 0 步加了“用测试 key 看 Codex 在各家厂商上会不会因搜索工具报错”。合计工作量从约 9–13 人天改成约 6.5–11 人天。
15. **行号改正。** `docs/agent-integration.md:105-107` 改成 `105-108`（Hermes 在第 108 行），进度文件补了第 11 行。来源里加了评审时重读的官方页面和源码（标 †），也加了新引用的仓库位置。