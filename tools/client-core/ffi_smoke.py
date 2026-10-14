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

class L(cc.EventListener):
    def on_event(self, e): pass
    def on_reset(self, o, l): pass
    def on_status(self, s): print("status", s)

async def main():
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
    print("cached", c.cached_instances(), c.cached_unread())
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
    print("ok")

asyncio.run(main())
