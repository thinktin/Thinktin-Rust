#!/usr/bin/env python3
"""模型网关的本地替身，供真实 agent 的冒烟测试使用（只用标准库）。

按网关的路径约定提供三种协议（见 crates/agent-shim/src/config.rs）：

- POST {root}/anthropic/v1/messages          Anthropic Messages（流式和非流式）
- POST {root}/openai/v1/chat/completions     OpenAI Chat Completions（流式和非流式）
- POST {root}/openai/v1/responses            OpenAI Responses（流式和非流式）
- GET  {root}/openai/v1/models、{root}/anthropic/v1/models

每个请求都必须带沙箱令牌（Authorization: Bearer、x-api-key 或 api-key），否则返回 401，
借此证明 agent 用的是 shim 注入的令牌。每个请求在 --log 里记一行 JSON。

回复规则：
- 最后一条消息是工具结果：回复 "MOCK_DONE: <结果前 200 字>"
- 用户消息里有 `MOCK_TOOL:<工具名>:<JSON 参数>`（参数写到行尾），且请求的工具列表里有这个工具：
  返回一次对该工具的调用
- 用户消息里有 `MOCK_SLOW`：慢慢输出一段长文字（约 8 秒），用来测取消
- 其他情况：回复 "pong from mock"
"""

import argparse
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOOL_RE = re.compile(r"MOCK_TOOL:([A-Za-z0-9_.-]+):(\{.*\})\s*$", re.M)
PONG = "pong from mock"
SLOW_TEXT = "slow " * 80

_counter = 0
_counter_lock = threading.Lock()


def next_id():
    global _counter
    with _counter_lock:
        _counter += 1
        return _counter


def text_of(content):
    """把各家协议里的 content（字符串或块列表）拼成纯文本。"""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict):
                if "text" in block and isinstance(block["text"], str):
                    parts.append(block["text"])
                elif "content" in block:
                    parts.append(text_of(block["content"]))
                elif "output" in block:
                    parts.append(text_of(block["output"]))
        return "\n".join(parts)
    if isinstance(content, dict):
        return text_of(content.get("text") or content.get("content"))
    return str(content)


def plan_reply(last_is_tool_result, tool_result_text, user_text, tool_names):
    """返回 ("text", 文本) 或 ("tool", 工具名, 参数 JSON 字符串)。"""
    if last_is_tool_result:
        return ("text", "MOCK_DONE: " + tool_result_text.strip()[:200])
    if "MOCK_SLOW" in (user_text or ""):
        return ("text", SLOW_TEXT)
    matches = TOOL_RE.findall(user_text or "")
    if matches:
        name, args = matches[-1]
        if name in tool_names:
            try:
                json.loads(args)
            except ValueError:
                return ("text", "MOCK_ERROR: bad tool args")
            return ("tool", name, args)
    return ("text", PONG)


# ---------- Anthropic Messages ----------


def last_turn(items, kind_of):
    """跳过 system、developer 等消息，返回最后一条用户、助手或工具结果消息及其类别。"""
    for item in reversed(items or []):
        kind = kind_of(item)
        if kind in ("user", "assistant", "tool_result"):
            return item, kind
    return {}, None


def anthropic_kind(m):
    role = str(m.get("role", "")).lower()
    content = m.get("content")
    if role == "user" and isinstance(content, list) and any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content
    ):
        return "tool_result"
    return role


def anthropic_plan(body):
    tools = [t.get("name") for t in body.get("tools") or [] if isinstance(t, dict)]
    last, kind = last_turn(body.get("messages"), anthropic_kind)
    content = last.get("content")
    if kind == "tool_result":
        results = [b for b in content if isinstance(b, dict) and b.get("type") == "tool_result"]
        return plan_reply(True, text_of([text_of(r.get("content")) for r in results]), "", tools), tools
    user_text = text_of(content) if kind == "user" else ""
    return plan_reply(False, "", user_text, tools), tools


def anthropic_response(handler, body, plan):
    model = body.get("model", "mock")
    usage = {"input_tokens": 12, "output_tokens": 6}
    if plan[0] == "tool":
        block = {"type": "tool_use", "id": f"toolu_mock_{next_id()}", "name": plan[1], "input": json.loads(plan[2])}
        stop = "tool_use"
    else:
        block = {"type": "text", "text": plan[1]}
        stop = "end_turn"
    msg_id = f"msg_mock_{next_id()}"
    if not body.get("stream"):
        return handler.send_json(200, {
            "id": msg_id, "type": "message", "role": "assistant", "model": model,
            "content": [block], "stop_reason": stop, "stop_sequence": None, "usage": usage,
        })
    handler.start_sse()
    handler.sse("message_start", {"type": "message_start", "message": {
        "id": msg_id, "type": "message", "role": "assistant", "model": model, "content": [],
        "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 12, "output_tokens": 1}}})
    if block["type"] == "text":
        handler.sse("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
        for piece in chunks(block["text"]):
            handler.sse("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": piece}})
    else:
        handler.sse("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {
            "type": "tool_use", "id": block["id"], "name": block["name"], "input": {}}})
        handler.sse("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {
            "type": "input_json_delta", "partial_json": plan[2]}})
    handler.sse("content_block_stop", {"type": "content_block_stop", "index": 0})
    handler.sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 6}})
    handler.sse("message_stop", {"type": "message_stop"})


# ---------- OpenAI Chat Completions ----------


def chat_kind(m):
    role = str(m.get("role", "")).lower()
    return "tool_result" if role == "tool" else role


def chat_plan(body):
    tools = [(t.get("function") or {}).get("name") for t in body.get("tools") or [] if isinstance(t, dict)]
    last, kind = last_turn(body.get("messages"), chat_kind)
    if kind == "tool_result":
        return plan_reply(True, text_of(last.get("content")), "", tools), tools
    user_text = text_of(last.get("content")) if kind == "user" else ""
    return plan_reply(False, "", user_text, tools), tools


def chat_response(handler, body, plan):
    model = body.get("model", "mock")
    cid = f"chatcmpl-mock-{next_id()}"
    created = int(time.time())
    usage = {"prompt_tokens": 12, "completion_tokens": 6, "total_tokens": 18}
    if plan[0] == "tool":
        call = {"id": f"call_mock_{next_id()}", "type": "function", "function": {"name": plan[1], "arguments": plan[2]}}
        message = {"role": "assistant", "content": None, "tool_calls": [call]}
        finish = "tool_calls"
    else:
        message = {"role": "assistant", "content": plan[1]}
        finish = "stop"
    if not body.get("stream"):
        return handler.send_json(200, {
            "id": cid, "object": "chat.completion", "created": created, "model": model,
            "choices": [{"index": 0, "message": message, "finish_reason": finish}], "usage": usage,
        })

    def chunk(delta, finish_reason=None):
        return {"id": cid, "object": "chat.completion.chunk", "created": created, "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}]}

    handler.start_sse()
    handler.sse(None, chunk({"role": "assistant", "content": ""}))
    if plan[0] == "tool":
        call = dict(message["tool_calls"][0], index=0)
        handler.sse(None, chunk({"tool_calls": [call]}))
    else:
        for piece in chunks(plan[1]):
            handler.sse(None, chunk({"content": piece}))
    handler.sse(None, chunk({}, finish))
    if (body.get("stream_options") or {}).get("include_usage"):
        handler.sse(None, {"id": cid, "object": "chat.completion.chunk", "created": created, "model": model,
                           "choices": [], "usage": usage})
    handler.sse_raw("data: [DONE]\n\n")


# ---------- OpenAI Responses ----------


def responses_kind(item):
    if item.get("type") in ("function_call_output", "custom_tool_call_output"):
        return "tool_result"
    if item.get("type") in ("function_call", "custom_tool_call", "reasoning"):
        return "assistant"
    return str(item.get("role", "")).lower()


def responses_plan(body):
    items = body.get("input")
    if isinstance(items, str):
        items = [{"role": "user", "content": items}]
    tools = [t.get("name") for t in body.get("tools") or [] if isinstance(t, dict)]
    last, kind = last_turn(items, responses_kind)
    if kind == "tool_result":
        return plan_reply(True, text_of(last.get("output")), "", tools), tools
    user_text = text_of(last.get("content")) if kind == "user" else ""
    return plan_reply(False, "", user_text, tools), tools


def responses_response(handler, body, plan):
    model = body.get("model", "mock")
    rid = f"resp_mock_{next_id()}"
    created = int(time.time())
    usage = {"input_tokens": 12, "input_tokens_details": {"cached_tokens": 0},
             "output_tokens": 6, "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 18}
    if plan[0] == "tool":
        item = {"type": "function_call", "id": f"fc_mock_{next_id()}", "call_id": f"call_mock_{next_id()}",
                "name": plan[1], "arguments": plan[2], "status": "completed"}
    else:
        item = {"type": "message", "id": f"msg_mock_{next_id()}", "status": "completed", "role": "assistant",
                "content": [{"type": "output_text", "text": plan[1], "annotations": []}]}
    base = {"id": rid, "object": "response", "created_at": created, "model": model}
    if not body.get("stream"):
        return handler.send_json(200, dict(base, status="completed", output=[item], usage=usage))
    seq = iter(range(1, 1000))
    handler.start_sse()

    def ev(kind, payload):
        handler.sse(kind, dict(payload, type=kind, sequence_number=next(seq)))

    ev("response.created", {"response": dict(base, status="in_progress", output=[])})
    ev("response.in_progress", {"response": dict(base, status="in_progress", output=[])})
    if item["type"] == "message":
        started = dict(item, status="in_progress", content=[])
        ev("response.output_item.added", {"output_index": 0, "item": started})
        part = {"type": "output_text", "text": "", "annotations": []}
        ev("response.content_part.added", {"item_id": item["id"], "output_index": 0, "content_index": 0, "part": part})
        for piece in chunks(plan[1]):
            ev("response.output_text.delta", {"item_id": item["id"], "output_index": 0, "content_index": 0, "delta": piece})
        ev("response.output_text.done", {"item_id": item["id"], "output_index": 0, "content_index": 0, "text": plan[1]})
        ev("response.content_part.done", {"item_id": item["id"], "output_index": 0, "content_index": 0,
                                          "part": item["content"][0]})
    else:
        ev("response.output_item.added", {"output_index": 0, "item": dict(item, status="in_progress", arguments="")})
        ev("response.function_call_arguments.delta", {"item_id": item["id"], "output_index": 0, "delta": plan[2]})
        ev("response.function_call_arguments.done", {"item_id": item["id"], "output_index": 0, "arguments": plan[2]})
    ev("response.output_item.done", {"output_index": 0, "item": item})
    ev("response.completed", {"response": dict(base, status="completed", output=[item], usage=usage)})


def chunks(text, size=8):
    return [text[i:i + size] for i in range(0, len(text), size)] or [""]


# ---------- HTTP ----------


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # agent 取消一轮时会直接断开流式连接，这是预期行为，不打印堆栈。
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mock-llm/1"

    def log_message(self, fmt, *args):  # 安静：日志写进 --log
        pass

    def record(self, **fields):
        entry = {"ts": round(time.time(), 3), "method": self.command, "path": self.path, **fields}
        # 扮演厂商时，检查请求里有没有不该出现的东西（比如沙箱令牌）。
        seen = getattr(self, "raw_body", b"").decode("utf-8", "replace") + "\n".join(f"{k}: {v}" for k, v in self.headers.items())
        hits = [f for f in self.server.forbid if f in seen]
        if hits:
            entry["forbidden_seen"] = hits
        with self.server.log_lock:
            self.server.log.write(json.dumps(entry, ensure_ascii=False) + "\n")
            self.server.log.flush()

    def auth(self):
        token = self.server.token
        bearer = self.headers.get("Authorization", "")
        presented = [
            bearer[7:] if bearer.lower().startswith("bearer ") else None,
            self.headers.get("x-api-key"),
            self.headers.get("api-key"),
        ]
        if any(p == token for p in presented if p):
            return "ok"
        return "bad" if any(presented) else "missing"

    def send_json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def start_sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def sse(self, event, data):
        head = f"event: {event}\n" if event else ""
        self.sse_raw(f"{head}data: {json.dumps(data)}\n\n")

    def sse_raw(self, text):
        self.wfile.write(text.encode())
        self.wfile.flush()
        if getattr(self, "slow", False):
            time.sleep(0.1)

    def route(self):
        path = self.path.split("?", 1)[0]
        root = self.server.root
        if not path.startswith(root):
            return None, None
        return path[len(root):], path

    def do_GET(self):
        sub, _ = self.route()
        auth = self.auth()
        self.record(auth=auth)
        if auth != "ok":
            return self.send_json(401, {"error": {"type": "authentication_error", "message": "bad sandbox token"}})
        if sub in ("/openai/v1/models", "/anthropic/v1/models"):
            data = [{"id": m, "object": "model", "type": "model", "display_name": m, "created_at": "2026-01-01T00:00:00Z",
                     "created": 0, "owned_by": "mock"} for m in self.server.models]
            return self.send_json(200, {"object": "list", "data": data, "has_more": False})
        self.send_json(404, {"error": {"message": f"no route {self.path}"}})

    def do_POST(self):
        sub, _ = self.route()
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        self.raw_body = raw
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        auth = self.auth()
        handlers = {
            "/anthropic/v1/messages": (anthropic_plan, anthropic_response),
            "/openai/v1/chat/completions": (chat_plan, chat_response),
            "/openai/v1/responses": (responses_plan, responses_response),
        }
        if sub == "/anthropic/v1/messages/count_tokens":
            self.record(auth=auth, model=body.get("model"))
            return self.send_json(200 if auth == "ok" else 401, {"input_tokens": 12})
        if sub not in handlers:
            self.record(auth=auth, error="no route")
            return self.send_json(404, {"error": {"message": f"no route {self.path}"}})
        if auth != "ok":
            self.record(auth=auth, model=body.get("model"))
            return self.send_json(401, {"type": "error", "error": {"type": "authentication_error", "message": "bad sandbox token"}})
        plan_fn, respond_fn = handlers[sub]
        plan, tools = plan_fn(body)
        self.slow = plan == ("text", SLOW_TEXT)
        if self.server.dump:
            with open(self.server.dump, "a", encoding="utf-8") as f:
                f.write(json.dumps({"path": self.path, "body": body}, ensure_ascii=False) + "\n")
        self.record(auth=auth, model=body.get("model"), stream=bool(body.get("stream")),
                    tools=sorted(t for t in tools if t), reply=plan[0] if plan[0] == "tool" else plan[1][:60],
                    tool=plan[1] if plan[0] == "tool" else None)
        respond_fn(self, body, plan)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=0, help="监听端口，0 表示随机")
    ap.add_argument("--root", default="", help="路径前缀，对应网关根地址里的路径部分")
    ap.add_argument("--token", required=True, help="期望的沙箱令牌")
    ap.add_argument("--log", required=True, help="请求日志（JSON Lines）")
    ap.add_argument("--model", action="append", default=None, help="模型列表接口返回的模型，可重复")
    ap.add_argument("--dump", default=None, help="把完整请求体追加到这个文件（调试用）")
    ap.add_argument("--forbid", action="append", default=[], help="请求头和请求体里不应出现的字符串，出现就记进日志，可重复")
    args = ap.parse_args()
    server = Server(("127.0.0.1", args.port), Handler)
    server.token = args.token
    server.root = args.root.rstrip("/")
    server.models = args.model or ["main", "fast"]
    server.log = open(args.log, "a", encoding="utf-8")
    server.log_lock = threading.Lock()
    server.dump = args.dump
    server.forbid = args.forbid
    print(f"listening on {server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
