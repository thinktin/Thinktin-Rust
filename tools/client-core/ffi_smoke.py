"""经 C ABI 冒烟测试 client-core 的绑定接口（不需要 Xcode / NDK）：用 UniFFI 生成的 Python 绑定
调用真实的动态库，覆盖错误类型、原生端实现的接口（会话存储、事件回调）、async 调用、订阅的开始和停止。

由 tools/client-core/ffi-smoke.sh 调用；参数是放着 client_core.py 和动态库的目录。
"""
import asyncio, sys, tempfile, os
sys.path.insert(0, sys.argv[1])
import client_core as cc

class Store(cc.SessionStore):
    def __init__(self): self.s = None; self.saves = 0
    def load(self): return self.s
    def save(self, session): self.s = session; self.saves += 1

class LogSink(cc.LogSink):
    def __init__(self): self.records = []
    def log(self, record): self.records.append(record)

class L(cc.EventListener):
    def on_event(self, e): pass
    def on_reset(self, o, l): pass
    def on_status(self, s): print("status", s)

async def main():
    logs = LogSink()
    assert cc.init_logging(logs, cc.LogLevel.DEBUG) is True
    # 记录类型上加的字段带默认值：App 里自己构造的地方（测试、预览）不用改。
    p = cc.PlanPolicy()
    assert (p.approval_timeout_secs, p.on_approval_timeout, p.max_duration_secs, p.preauthorized_tools) == \
        (86400, "pause_plan", 21600, []), p
    plan = cc.Plan(id="p", instance_id="i", title="t", goal="g", paused=False, created_by="user",
                   awaiting_confirmation=False, revision=1, policy_json="{}", created_at_ms=0,
                   triggers=[], steps=[])
    assert plan.catch_up == "once" and plan.policy == p, plan
    # 收件箱条目后加的字段（保险箱、出网、项目回执）默认是空的。
    item = cc.InboxItem(id="x", instance_id=None, run_id=None, plan_id=None, approval_id=None, kind="info",
                        title="t", body="b", ai_generated=False, read=False, created_at_ms=0)
    assert (item.subtype, item.vault_request_id, item.egress_request_id, item.project_id,
            item.project_invite_id) == (None, None, None, None, None), item
    # 运行后加的项目 id（8.15）默认是空的。
    run = cc.Run(id="r", kind="agent", instance_id="i", plan_id=None, parent_run_id=None, root_run_id="r",
                 step_key=None, source="user", prompt="p", state="queued", state_reason=None, attempt=0,
                 tokens_used=0, summary=None, error=None, created_at_ms=0, started_at_ms=None,
                 finished_at_ms=None)
    assert (run.wait_code, run.project_id) == (None, None), run
    # 专属的 botin（8.16）：加入的一项只给 instance_id 就行，别的默认关；说明的版本是 2。
    entry = cc.ProjectJoinAgent(instance_id="i")
    assert (entry.adopt, entry.dedicated, entry.reset_workspace, entry.ack_shared_memory) == \
        (None, False, False, False), entry
    assert cc.ProjectAdopt(agent_id="claude", name="n").harness is None
    assert cc.project_consent_version() == 2
    inst = cc.Instance(id="i", agent_id="claude", agent_version="1", harness="acp", name="n", state="ready",
                       created_at_ms=0, last_active_at_ms=0)
    assert inst.dedicated_project_id is None, inst
    store = Store()
    d = tempfile.mkdtemp()
    cfg = cc.ClientConfig(base_url="http://127.0.0.1:9", cache_path=os.path.join(d, "c.db"),
                          platform="ios", device_name="py", timeout_secs=5)
    try:
        cc.ThinktinClient(cc.ClientConfig(base_url="x", cache_path=None, platform="nope", device_name="", timeout_secs=5), store)
        raise SystemExit("expected error")
    except cc.ClientError.InvalidArgument as e:
        print("invalid platform ->", e)
    c = cc.ThinktinClient(cfg, store)
    print("signed_in", c.signed_in())
    assert c.upgrade_required() is False
    assert cc.RunFilter().active_only is False
    c.set_accept_language("en-US, en;q=0.9")
    assert cc.accept_language_header(["zh-Hans-CN", "en"]) == "zh-Hans-CN, en;q=0.9"
    print("cached", c.cached_instances(), c.cached_unread())
    assert c.cached_events_before("01890000-0000-7000-8000-000000000000", None, 10) == []
    try:
        await c.me()
    except cc.ClientError.SignedOut:
        print("me -> SignedOut")
    try:
        await c.send_code("13800138000")
    except cc.ClientError.Network as e:
        print("send_code -> Network")
    store.s = cc.Session(user_id="0192f0c4-0000-7000-8000-000000000001", device_id="d", access_token="a", refresh_token="r")
    c2 = cc.ThinktinClient(cfg, store)
    print("restored session signed_in", c2.signed_in())
    sub = c2.subscribe("0192f0c4-0000-7000-8000-000000000002", L())
    await asyncio.sleep(0.3)
    sub.stop()
    await asyncio.sleep(0.2)
    try:
        await c2.mark_inbox_read(["bad"], None)
    except cc.ClientError.InvalidArgument:
        print("bad id -> InvalidArgument")
    # 项目里的内容（8.15）：只走网络，没网就是 Network。
    try:
        await c2.project_runs("bad", None, None, 10)
        raise SystemExit("expected InvalidArgument")
    except cc.ClientError.InvalidArgument:
        print("project_runs bad id -> InvalidArgument")
    try:
        await c2.project_run_events("0192f0c4-0000-7000-8000-000000000003",
                                    "0192f0c4-0000-7000-8000-000000000004", 10)
        raise SystemExit("expected Network")
    except cc.ClientError.Network:
        print("project_run_events -> Network")
    # 加入时每一项 instance_id 和 adopt 二选一：本地就报错，不联网。
    join = cc.ProjectJoin(agents=[cc.ProjectJoinAgent()], daily_token_limit=1, total_token_limit=1, consent=True)
    try:
        await c2.accept_project_invite_link("tpi1_" + "A" * 43, join)
        raise SystemExit("expected InvalidArgument")
    except cc.ClientError.InvalidArgument:
        print("join entry without instance_id or adopt -> InvalidArgument")
    try:
        await c2.release_instance("0192f0c4-0000-7000-8000-000000000005")
        raise SystemExit("expected Network")
    except cc.ClientError.Network:
        print("release_instance -> Network")
    # 项目里的协作（8.17）：流水线一步的依赖默认是空的；id 不对本地就报错，像密码的先拦下，没网就是 Network。
    step = cc.ProjectPipelineStep(key="a", instance_id="i", prompt="p")
    assert step.depends_on == [], step
    pid = "0192f0c4-0000-7000-8000-000000000006"
    try:
        await c2.project_board("bad", None, False, None, 20)
        raise SystemExit("expected InvalidArgument")
    except cc.ClientError.InvalidArgument:
        print("project_board bad id -> InvalidArgument")
    try:
        await c2.project_board(pid, None, False, None, 20)
        raise SystemExit("expected Network")
    except cc.ClientError.Network:
        print("project_board -> Network")
    try:
        await c2.create_project_task(pid, None, "mail 密码是 Abc12345", False)
        raise SystemExit("expected ContainsSecrets")
    except cc.ClientError.ContainsSecrets:
        print("create_project_task with a password -> ContainsSecrets")
    try:
        await c2.create_project_task(pid, None, "write the brief", False)
        raise SystemExit("expected Network")
    except cc.ClientError.Network:
        print("create_project_task -> Network")
    try:
        await c2.start_project_pipeline(pid, "t", "", [cc.ProjectPipelineStep(key="a", instance_id="bad", prompt="p")], False)
        raise SystemExit("expected InvalidArgument")
    except cc.ClientError.InvalidArgument:
        print("start_project_pipeline bad agent id -> InvalidArgument")
    # 输入里的密码拦截（11.6）：本地识别，位置是 UTF-16 下标；发送时拦下；换成引用。
    msg = "我的 github 密码是 Abc12345，帮我登录"
    found = cc.detect_secrets(msg)
    assert len(found) == 1 and found[0].value == "Abc12345", found
    assert msg[found[0].start:found[0].end] == "Abc12345", found
    assert found[0].suggested_name == "github" and found[0].storable
    print("detect_secrets ->", found[0].kind, found[0].suggested_name)
    try:
        await c2.send_message("0192f0c4-0000-7000-8000-000000000002", msg, False)
        raise SystemExit("expected ContainsSecrets")
    except cc.ClientError.ContainsSecrets as e:
        print("send_message -> ContainsSecrets", e.count)
    red = cc.redact_message(msg, [cc.SecretReference(value="Abc12345", name="github")])
    assert red == "我的 github 密码是 [vault:github]，帮我登录", red
    assert cc.detect_secrets(red) == []
    assert cc.unique_vault_name("GitHub", ["github"]) == "github_2"
    assert any(r.target.startswith("client_core") for r in logs.records), [r.message for r in logs.records]
    print("ok")

asyncio.run(main())
