#!/usr/bin/env python3
"""给 UniFFI 生成的 client_core.kt 打一个兼容补丁（sync-core.sh 调用，幂等）。

UniFFI 0.32 给错误枚举里名叫 `message` 的字段生成
    class Network(val `message`: kotlin.String) : ClientException() {
        override val message
            get() = "message=${ `message` }"
    }
和 Throwable.message 冲突，Kotlin 2.x 编译不过（Conflicting declarations / Overload resolution ambiguity）。
这里把字段改成 `override val message`，删掉那个拼字符串的 getter：Throwable.message 就是字段本身。
crates/client-core 里把这些字段改名（比如 detail）之后，本补丁什么也不做。

用法：patch-bindings.py <client_core.kt>（原地修改）
"""
import re
import sys

FIELD = re.compile(r"^(\s+)val `message`: kotlin\.String(\s*,?\s*)$")
GETTER = re.compile(r"^\s+override val message\s*$")
CLASS_END = re.compile(r"^\s+\}\s*$")


def patch(lines):
    out = []
    pending = False  # 当前错误变体的字段已改成 override，等着删掉它的 getter
    skip_get = False
    changed = 0
    for line in lines:
        if skip_get:
            skip_get = False
            if line.strip().startswith("get() ="):
                continue
        m = FIELD.match(line.rstrip("\n"))
        if m:
            out.append(f"{m.group(1)}override val `message`: kotlin.String{m.group(2)}\n")
            pending = True
            changed += 1
            continue
        if pending and GETTER.match(line):
            pending = False
            skip_get = True
            continue
        if pending and CLASS_END.match(line):
            pending = False
        out.append(line)
    return out, changed


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()
    out, changed = patch(lines)
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(out)
    print(f"patch-bindings: {changed} 个 message 字段改为 override（{path}）")


if __name__ == "__main__":
    main()
